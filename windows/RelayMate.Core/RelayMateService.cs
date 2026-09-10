namespace RelayMate.Core;

public sealed class RelayMateService
{
    private readonly IReadOnlyDictionary<ClientKind, IConfigurationAdapter> _adapters;
    private readonly BackupStore _backups;
    private readonly ConnectivityTester _connectivity;

    public RelayMateService(
        WindowsRelayMatePaths? paths = null,
        ConnectivityTester? connectivity = null)
    {
        Paths = paths ?? new WindowsRelayMatePaths();
        _connectivity = connectivity ?? new ConnectivityTester();
        _backups = new BackupStore(Paths.SupportDirectory);
        _adapters = new Dictionary<ClientKind, IConfigurationAdapter>
        {
            [ClientKind.Claude] = new ClaudeConfigurationAdapter(Paths),
            [ClientKind.Codex] = new CodexConfigurationAdapter(Paths)
        };
    }

    public WindowsRelayMatePaths Paths { get; }

    public RelayConfiguration? CurrentConfiguration(ClientKind client) => Adapter(client).CurrentConfiguration();

    public ConfigurationStatus Status(ClientKind client)
    {
        try
        {
            var backupStatus = _backups.Status(client);
            if (backupStatus != ConfigurationStatus.NotConfigured)
            {
                return backupStatus;
            }
            return Adapter(client).CurrentConfiguration() is null
                ? ConfigurationStatus.NotConfigured
                : ConfigurationStatus.External;
        }
        catch (RelayMateException)
        {
            return ConfigurationStatus.Invalid;
        }
    }

    public Task<ModelCatalog> FetchModelsAsync(
        string baseUrl,
        string apiKey,
        CancellationToken cancellationToken = default) =>
        _connectivity.FetchModelsAsync(baseUrl, apiKey, cancellationToken);

    public async Task ApplyAsync(
        ClientKind client,
        RelayConfiguration configuration,
        CancellationToken cancellationToken = default)
    {
        var normalized = configuration.Normalize();
        _ = ConnectivityTester.ValidateBaseUri(normalized.BaseUrl);
        if (normalized.Model.Length == 0)
        {
            throw RelayMateException.MissingModel();
        }
        if (normalized.ApiKey.Length == 0)
        {
            throw RelayMateException.MissingApiKey();
        }
        await _connectivity.ValidateAsync(normalized, client, cancellationToken);

        var adapter = Adapter(client);
        _backups.EnsureBaseline(client, adapter.ManagedPaths);
        adapter.Apply(normalized);
        _backups.MarkApplied(client, adapter.ManagedPaths);
    }

    public void Restore(ClientKind client, bool force = false) => _backups.Restore(client, force);

    private IConfigurationAdapter Adapter(ClientKind client) => _adapters[client];
}
