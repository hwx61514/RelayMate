namespace RelayMate.Core;

public sealed class WindowsRelayMatePaths
{
    public WindowsRelayMatePaths(
        string? homeDirectory = null,
        string? localAppDataDirectory = null,
        string? supportDirectory = null,
        string? codexHome = null)
    {
        HomeDirectory = Path.GetFullPath(
            homeDirectory
            ?? Environment.GetEnvironmentVariable("RELAY_SETUP_HOME")
            ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

        LocalAppDataDirectory = Path.GetFullPath(
            localAppDataDirectory
            ?? Environment.GetEnvironmentVariable("RELAY_SETUP_LOCALAPPDATA")
            ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));

        SupportDirectory = Path.GetFullPath(
            supportDirectory
            ?? Environment.GetEnvironmentVariable("RELAY_SETUP_SUPPORT_DIR")
            ?? Path.Combine(LocalAppDataDirectory, "RelayMate"));

        var configuredCodexHome = codexHome ?? Environment.GetEnvironmentVariable("CODEX_HOME");
        CodexDirectory = Path.GetFullPath(string.IsNullOrWhiteSpace(configuredCodexHome)
            ? Path.Combine(HomeDirectory, ".codex")
            : configuredCodexHome);
    }

    public string HomeDirectory { get; }
    public string LocalAppDataDirectory { get; }
    public string SupportDirectory { get; }
    public string CodexDirectory { get; }

    public string ClaudeCodeSettings => Path.Combine(HomeDirectory, ".claude", "settings.json");
    public string ClaudeDesktopConfig => Path.Combine(LocalAppDataDirectory, "Claude", "claude_desktop_config.json");
    public string ClaudeThirdPartyDirectory => Path.Combine(LocalAppDataDirectory, "Claude-3p");
    public string ClaudeThirdPartyConfig => Path.Combine(ClaudeThirdPartyDirectory, "claude_desktop_config.json");
    public string ClaudeConfigLibrary => Path.Combine(ClaudeThirdPartyDirectory, "configLibrary");
    public string ClaudeProfile => Path.Combine(ClaudeConfigLibrary, $"{ClaudeConfigurationAdapter.DesktopProfileId}.json");
    public string ClaudeMeta => Path.Combine(ClaudeConfigLibrary, "_meta.json");

    public string CodexConfig => Path.Combine(CodexDirectory, "config.toml");
    public string CodexLegacyProfile => Path.Combine(CodexDirectory, $"{CodexConfigurationAdapter.ProfileName}.config.toml");
    public string CodexCatalog => Path.Combine(CodexDirectory, CodexConfigurationAdapter.CatalogFileName);
    public string CodexModelCache => Path.Combine(CodexDirectory, "models_cache.json");
    public string CodexSessions => Path.Combine(CodexDirectory, "sessions");
}
