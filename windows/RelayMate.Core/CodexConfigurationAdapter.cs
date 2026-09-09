using System.Text;
using System.Text.Json.Nodes;

namespace RelayMate.Core;

public sealed class CodexConfigurationAdapter : IConfigurationAdapter
{
    public const string ProfileName = "relay-setup";
    public const string CatalogFileName = "relaymate-model-catalog.json";

    private readonly WindowsRelayMatePaths _paths;

    public CodexConfigurationAdapter(WindowsRelayMatePaths paths)
    {
        _paths = paths;
        ManagedPaths = [paths.CodexConfig, paths.CodexLegacyProfile, paths.CodexCatalog];
    }

    public ClientKind Client => ClientKind.Codex;
    public IReadOnlyList<string> ManagedPaths { get; }

    public RelayConfiguration? CurrentConfiguration()
    {
        if (!File.Exists(_paths.CodexConfig))
        {
            return null;
        }

        string text;
        try
        {
            text = File.ReadAllText(_paths.CodexConfig, Encoding.UTF8);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw RelayMateException.InvalidConfiguration(exception.Message);
        }

        var model = TomlText.TopLevelValue("model", text);
        if (model is null)
        {
            return null;
        }
        var enabledModels = ReadOwnedCatalog(text) ?? [model];
        var provider = TomlText.TopLevelValue("model_provider", text) ?? "openai";
        if (provider == "openai" && TomlText.TopLevelValue("openai_base_url", text) is { } openAiBaseUrl)
        {
            return new RelayConfiguration(openAiBaseUrl, model, string.Empty, enabledModels);
        }

        var providerText = TomlText.Table($"model_providers.{provider}", text);
        var baseUrl = providerText is null ? null : TomlText.Value("base_url", providerText);
        if (baseUrl is null)
        {
            return null;
        }
        var key = TomlText.Value("experimental_bearer_token", providerText!) ?? string.Empty;
        var redirected = TomlText.TableNames("model_providers", text)
            .Where(name => name != provider && name != ProfileName)
            .Where(name => TomlText.Table($"model_providers.{name}", text) is { } table
                && TomlText.Value("base_url", table) == baseUrl)
            .ToList();
        return new RelayConfiguration(baseUrl, model, key, enabledModels, null, redirected);
    }

    public void Apply(RelayConfiguration input)
    {
        var configuration = input.Normalize();
        var enabledModels = configuration.EffectiveEnabledModels;
        if (!enabledModels.Contains(configuration.Model, StringComparer.Ordinal))
        {
            throw RelayMateException.Incompatible("默认模型必须包含在已启用模型中。");
        }

        var originalMain = SecureFileSystem.Snapshot(_paths.CodexConfig);
        var originalProfile = SecureFileSystem.Snapshot(_paths.CodexLegacyProfile);
        var originalCatalog = SecureFileSystem.Snapshot(_paths.CodexCatalog);
        try
        {
            var mainText = originalMain.Existed
                ? Encoding.UTF8.GetString(originalMain.Contents ?? [])
                : string.Empty;
            var updated = TomlText.RemoveTopLevelString("profile", ProfileName, mainText);
            updated = TomlText.SetTopLevelString("model", configuration.Model, updated);
            updated = TomlText.SetTopLevelString("model_provider", ProfileName, updated);
            updated = TomlText.SetTopLevelString("model_catalog_json", CatalogFileName, updated);
            updated = TomlText.SetTable($"model_providers.{ProfileName}", Provider(configuration), updated);

            foreach (var name in configuration.CodexRedirectedProviders ?? [])
            {
                if (name == ProfileName)
                {
                    continue;
                }
                var tableName = $"model_providers.{name}";
                var displayName = TomlText.Table(tableName, updated) is { } table
                    ? TomlText.Value("name", table) ?? name
                    : name;
                updated = TomlText.SetTable(tableName, Provider(configuration, displayName), updated);
            }

            WriteCatalog(configuration.Model, enabledModels);
            SecureFileSystem.Write(Encoding.UTF8.GetBytes(updated), _paths.CodexConfig);
            if (File.Exists(_paths.CodexLegacyProfile))
            {
                File.Delete(_paths.CodexLegacyProfile);
            }
        }
        catch
        {
            TryRestore(originalCatalog);
            TryRestore(originalProfile);
            TryRestore(originalMain);
            throw;
        }
    }

    private IReadOnlyList<string>? ReadOwnedCatalog(string configText)
    {
        var pointer = TomlText.TopLevelValue("model_catalog_json", configText);
        if (pointer is null || !string.Equals(Path.GetFileName(pointer), CatalogFileName, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }
        if (!File.Exists(_paths.CodexCatalog))
        {
            throw RelayMateException.InvalidConfiguration("RelayMate 的 Codex 模型目录不存在。");
        }

        try
        {
            var root = JsonNode.Parse(File.ReadAllText(_paths.CodexCatalog, Encoding.UTF8).TrimStart('\uFEFF')) as JsonObject;
            var identifiers = (root?["models"] as JsonArray ?? [])
                .OfType<JsonObject>()
                .Select(model => JsonFiles.String(model, "slug"))
                .Where(model => !string.IsNullOrWhiteSpace(model))
                .Cast<string>()
                .ToList();
            return identifiers.Count > 0
                ? identifiers
                : throw RelayMateException.InvalidConfiguration("RelayMate 的 Codex 模型目录为空。");
        }
        catch (System.Text.Json.JsonException)
        {
            throw RelayMateException.InvalidConfiguration("RelayMate 的 Codex 模型目录无法读取。");
        }
    }

    private void WriteCatalog(string defaultModel, IReadOnlyList<string> enabledModels)
    {
        var ordered = new[] { defaultModel }
            .Concat(enabledModels.Where(model => model != defaultModel))
            .ToList();
        var cached = CachedModelMetadata();
        var entries = new JsonArray();
        for (var index = 0; index < ordered.Count; index++)
        {
            var model = ordered[index];
            var entry = cached.TryGetValue(model, out var metadata)
                ? (JsonObject)metadata.DeepClone()
                : FallbackCatalogEntry(model);
            entry["slug"] = model;
            entry["display_name"] = model;
            entry["description"] = model;
            entry["visibility"] = "list";
            entry["supported_in_api"] = true;
            entry["priority"] = 1000 + index;
            entry["additional_speed_tiers"] = new JsonArray();
            entry["service_tiers"] = new JsonArray();
            entry.Remove("default_service_tier");
            entries.Add(entry);
        }
        JsonFiles.WriteObject(new JsonObject { ["models"] = entries }, _paths.CodexCatalog);
    }

    private Dictionary<string, JsonObject> CachedModelMetadata()
    {
        if (!File.Exists(_paths.CodexModelCache))
        {
            return new Dictionary<string, JsonObject>(StringComparer.Ordinal);
        }
        try
        {
            var root = JsonNode.Parse(File.ReadAllText(_paths.CodexModelCache, Encoding.UTF8).TrimStart('\uFEFF')) as JsonObject;
            return (root?["models"] as JsonArray ?? [])
                .OfType<JsonObject>()
                .Where(item => JsonFiles.String(item, "slug") is not null)
                .ToDictionary(item => JsonFiles.String(item, "slug")!, item => item, StringComparer.Ordinal);
        }
        catch
        {
            return new Dictionary<string, JsonObject>(StringComparer.Ordinal);
        }
    }

    private static JsonObject FallbackCatalogEntry(string model) => new()
    {
        ["slug"] = model,
        ["display_name"] = model,
        ["description"] = model,
        ["base_instructions"] = "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals.",
        ["default_reasoning_level"] = "high",
        ["supported_reasoning_levels"] = new JsonArray
        {
            new JsonObject { ["effort"] = "none", ["description"] = "Disable Thinking" },
            new JsonObject { ["effort"] = "high", ["description"] = "Enabled Thinking" }
        },
        ["shell_type"] = "shell_command",
        ["visibility"] = "list",
        ["supported_in_api"] = true,
        ["priority"] = 0,
        ["supports_reasoning_summaries"] = true,
        ["default_reasoning_summary"] = "none",
        ["support_verbosity"] = false,
        ["truncation_policy"] = new JsonObject { ["mode"] = "bytes", ["limit"] = 10_000 },
        ["supports_parallel_tool_calls"] = false,
        ["supports_image_detail_original"] = false,
        ["context_window"] = 128_000,
        ["max_context_window"] = 128_000,
        ["effective_context_window_percent"] = 95,
        ["experimental_supported_tools"] = new JsonArray(),
        ["input_modalities"] = new JsonArray("text", "image"),
        ["supports_search_tool"] = false
    };

    private static string Provider(RelayConfiguration configuration, string displayName = "API Relay") =>
        $"name = {TomlText.Quote(displayName)}\n" +
        $"base_url = {TomlText.Quote(configuration.BaseUrl)}\n" +
        "wire_api = \"responses\"\n" +
        "requires_openai_auth = false\n" +
        $"experimental_bearer_token = {TomlText.Quote(configuration.ApiKey)}\n";

    private static void TryRestore(FileSnapshot snapshot)
    {
        try
        {
            SecureFileSystem.Restore(snapshot);
        }
        catch
        {
            // The original failure is more useful; the immutable BackupStore still permits manual recovery.
        }
    }
}
