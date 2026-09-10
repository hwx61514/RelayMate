using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RelayMate.Core;
using Windows.Graphics;

namespace RelayMate.Windows;

public sealed partial class MainWindow : Window
{
    private readonly RelayMateService _service = new();
    private IReadOnlySet<string> _oneMillionModels = new HashSet<string>();
    private bool _refreshing;

    public MainWindow()
    {
        InitializeComponent();
        StartupDiagnostics.Log("Main window XAML initialized.");
        ClientPicker.SelectedIndex = 0;
        _ = RefreshAsync();
    }

    private ClientKind SelectedClient =>
        ClientPicker.SelectedItem is ComboBoxItem { Tag: "Codex" }
            ? ClientKind.Codex
            : ClientKind.Claude;

    private async void ClientPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_refreshing)
        {
            await RefreshAsync();
        }
    }

    private async void LoadModelsButton_Click(object sender, RoutedEventArgs e)
    {
        await RunBusyAsync(async () =>
        {
            var catalog = await _service.FetchModelsAsync(BaseUrlBox.Text, ApiKeyBox.Password);
            var models = SelectedClient == ClientKind.Claude
                ? catalog.Models.Where(ClaudeConfigurationAdapter.IsClaudeDesktopModelId).ToList()
                : catalog.Models.ToList();
            if (models.Count == 0)
            {
                throw RelayMateException.Incompatible("模型列表中没有当前客户端支持的模型。");
            }
            _oneMillionModels = catalog.OneMillionContextModels;
            SetModels(models, models, models[0]);
            SetStatus($"已读取 {models.Count} 个可用模型。", StatusKind.Success);
        });
    }

    private void ModelsList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var selected = ModelsList.SelectedItems.Cast<string>().ToList();
        var previous = DefaultModelPicker.SelectedItem as string;
        DefaultModelPicker.ItemsSource = selected;
        DefaultModelPicker.SelectedItem = previous is not null && selected.Contains(previous)
            ? previous
            : selected.FirstOrDefault();
    }

    private async void ApplyButton_Click(object sender, RoutedEventArgs e)
    {
        await RunBusyAsync(async () =>
        {
            var enabled = ModelsList.SelectedItems.Cast<string>().ToList();
            var model = DefaultModelPicker.SelectedItem as string ?? string.Empty;
            var configuration = new RelayConfiguration(
                BaseUrlBox.Text,
                model,
                ApiKeyBox.Password,
                enabled,
                _oneMillionModels.Where(enabled.Contains).ToHashSet(StringComparer.Ordinal));
            await _service.ApplyAsync(SelectedClient, configuration);
            SetStatus(
                SelectedClient == ClientKind.Claude
                    ? "配置已应用。请完全退出 Claude Desktop 和 Claude Code 后重新打开。"
                    : "配置已应用。请重新打开 Codex。",
                StatusKind.Success);
            RestoreButton.IsEnabled = true;
        });
    }

    private async void RestoreButton_Click(object sender, RoutedEventArgs e)
    {
        await RunBusyAsync(async () =>
        {
            try
            {
                _service.Restore(SelectedClient);
            }
            catch (RelayMateException exception) when (exception.Message.Contains("继续还原会覆盖", StringComparison.Ordinal))
            {
                var dialog = new ContentDialog
                {
                    XamlRoot = Content.XamlRoot,
                    Title = "配置已被其他程序修改",
                    Content = exception.Message,
                    PrimaryButtonText = "仍然还原",
                    CloseButtonText = "取消",
                    DefaultButton = ContentDialogButton.Close
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary)
                {
                    return;
                }
                _service.Restore(SelectedClient, force: true);
            }
            RefreshState(updateStatus: false);
            SetStatus("原始配置已经还原。", StatusKind.Success);
        });
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private Task RefreshAsync() => RunBusyAsync(() =>
    {
        RefreshState();
        return Task.CompletedTask;
    });

    private void RefreshState(bool updateStatus = true)
    {
        _refreshing = true;
        try
        {
            var client = SelectedClient;
            var status = _service.Status(client);
            var current = _service.CurrentConfiguration(client);
            if (current is not null)
            {
                BaseUrlBox.Text = current.BaseUrl;
                ApiKeyBox.Password = current.ApiKey;
                _oneMillionModels = current.OneMillionContextModels ?? new HashSet<string>();
                SetModels(current.EffectiveEnabledModels, current.EffectiveEnabledModels, current.Model);
            }
            else
            {
                BaseUrlBox.Text = string.Empty;
                ApiKeyBox.Password = string.Empty;
                _oneMillionModels = new HashSet<string>();
                SetModels([], [], null);
            }
            RestoreButton.IsEnabled = status is ConfigurationStatus.Configured or ConfigurationStatus.Changed;
            if (updateStatus)
            {
                SetStatus(StatusMessage(status), status switch
                {
                    ConfigurationStatus.Configured => StatusKind.Success,
                    ConfigurationStatus.Changed or ConfigurationStatus.Invalid => StatusKind.Error,
                    ConfigurationStatus.External => StatusKind.Warning,
                    _ => StatusKind.Info
                });
            }
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void SetModels(
        IReadOnlyList<string> models,
        IReadOnlyCollection<string> enabled,
        string? defaultModel)
    {
        ModelsList.ItemsSource = models;
        ModelsList.SelectedItems.Clear();
        foreach (var model in models.Where(enabled.Contains))
        {
            ModelsList.SelectedItems.Add(model);
        }
        DefaultModelPicker.ItemsSource = enabled.ToList();
        DefaultModelPicker.SelectedItem = defaultModel is not null && enabled.Contains(defaultModel)
            ? defaultModel
            : enabled.FirstOrDefault();
    }

    private async Task RunBusyAsync(Func<Task> action)
    {
        if (BusyRing.IsActive)
        {
            return;
        }
        BusyRing.IsActive = true;
        BusyRing.Visibility = Visibility.Visible;
        ApplyButton.IsEnabled = false;
        LoadModelsButton.IsEnabled = false;
        try
        {
            await action();
        }
        catch (Exception exception)
        {
            SetStatus(exception.Message, StatusKind.Error);
        }
        finally
        {
            BusyRing.IsActive = false;
            BusyRing.Visibility = Visibility.Collapsed;
            ApplyButton.IsEnabled = true;
            LoadModelsButton.IsEnabled = true;
        }
    }

    private void SetStatus(string message, StatusKind kind)
    {
        StatusText.Text = message;
        StatusIcon.Glyph = kind switch
        {
            StatusKind.Success => "\uE73E",
            StatusKind.Warning => "\uE7BA",
            StatusKind.Error => "\uEA39",
            _ => "\uE946"
        };
        StatusIcon.Foreground = kind switch
        {
            StatusKind.Success => (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["RelayMateSuccessBrush"],
            StatusKind.Warning => (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["RelayMateWarningBrush"],
            StatusKind.Error => (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["RelayMateErrorBrush"],
            _ => StatusText.Foreground
        };
    }

    private static string StatusMessage(ConfigurationStatus status) => status switch
    {
        ConfigurationStatus.NotConfigured => "未检测到中转配置。",
        ConfigurationStatus.External => "检测到非 RelayMate 管理的配置；首次应用前会完整备份。",
        ConfigurationStatus.Configured => "当前配置由 RelayMate 管理。",
        ConfigurationStatus.Changed => "配置在应用后被其他程序修改；还原时需要确认。",
        ConfigurationStatus.Invalid => "现有配置无法读取，请检查配置文件格式和权限。",
        _ => string.Empty
    };

    internal void ResizeAfterActivation()
    {
        var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);
        AppWindow.GetFromWindowId(windowId).Resize(new SizeInt32(820, 720));
    }

    private enum StatusKind { Info, Success, Warning, Error }
}
