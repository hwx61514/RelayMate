using Microsoft.UI.Xaml;

namespace RelayMate.Windows;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        StartupDiagnostics.Install();
        try
        {
            InitializeComponent();
            UnhandledException += (_, args) =>
                StartupDiagnostics.ReportFatal("WinUI unhandled exception", args.Exception);
            StartupDiagnostics.Log("WinUI application initialized.");
        }
        catch (Exception exception)
        {
            StartupDiagnostics.ReportFatal("InitializeComponent", exception);
            throw;
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            StartupDiagnostics.Log("Creating main window.");
            _window = new MainWindow();
            _window.Activate();
            ((MainWindow)_window).ResizeAfterActivation();
            StartupDiagnostics.Log("Main window activated.");
        }
        catch (Exception exception)
        {
            StartupDiagnostics.ReportFatal("Create or activate main window", exception);
            throw;
        }
    }
}
