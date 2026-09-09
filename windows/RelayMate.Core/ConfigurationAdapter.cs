namespace RelayMate.Core;

public interface IConfigurationAdapter
{
    ClientKind Client { get; }
    IReadOnlyList<string> ManagedPaths { get; }
    RelayConfiguration? CurrentConfiguration();
    void Apply(RelayConfiguration configuration);
}
