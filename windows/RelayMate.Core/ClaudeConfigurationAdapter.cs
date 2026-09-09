using System.Text.Json.Nodes;

namespace RelayMate.Core;

public sealed class ClaudeConfigurationAdapter : IConfigurationAdapter
{
    public const string DesktopProfileId = "9b0875b6-24d4-4c87-9b3e-5df2b9a50d61";

    private readonly WindowsRelayMatePaths _paths;

    public ClaudeConfigurationAdapter(WindowsRelayMatePaths paths)
    {
        _paths = paths;
        ManagedPaths =
        [
            paths.ClaudeCodeSettings,
            paths.ClaudeDesktopConfig,
            paths.ClaudeThirdPartyConfig,
            paths.ClaudeProfile,
            paths.ClaudeMeta
        ];
    }

    public ClientKind Client => ClientKind.Claude;
    public IReadOnlyList<string> ManagedPaths { get; }

    public RelayConfiguration? CurrentConfiguration()
    {
        var desktop = ReadDesktopConfiguration();
        if (File.Exists(_paths.ClaudeCodeSettings))
        {
            var root = JsonFiles.ReadObject(_paths.ClaudeCodeSettings, "Claude Code settings.json");
            if (root["env"] is not null and not JsonObject)
            {
                throw RelayMateException.InvalidConfiguration("Claude Code 的 env 字段必须是对象。");
            }

            if (root["env"] is JsonObject environment)
            {
                var baseUrl = JsonFiles.String(environment, "ANTHROPIC_BASE_URL");
                var model = JsonFiles.String(environment, "ANTHROPIC_MODEL");
                if (!string.IsNullOrWhiteSpace(baseUrl) && !string.IsNullOrWhiteSpace(model))
                {
                    var key = JsonFiles.String(environment, "ANTHROPIC_AUTH_TOKEN")
                        ?? JsonFiles.String(environment, "ANTHROPIC_API_KEY")
                        ?? string.Empty;
                    return new RelayConfiguration(
                        baseUrl,
                        model,
                        key,
                        desktop?.EffectiveEnabledModels ?? [model],
                        desktop?.OneMillionContextModels ?? new HashSet<string>());
                }
            }
        }

        if (desktop is not null)
        {
            return desktop;
        }

        return DesktopUsesThirdPartyDeployment()
            ? new RelayConfiguration(string.Empty, string.Empty, string.Empty)
            : null;
    }

    public void Apply(RelayConfiguration input)
    {
        var configuration = input.Normalize();
        var enabledModels = configuration.EffectiveEnabledModels;
        if (!enabledModels.Contains(configuration.Model, StringComparer.Ordinal))
        {
            throw RelayMateException.Incompatible("默认模型必须包含在已启用模型中。");
        }
        if (enabledModels.Any(model => !IsClaudeDesktopModelId(model)))
        {
            throw RelayMateException.Incompatible(
                "Claude 桌面应用只接受 claude-sonnet-*、claude-opus-*、claude-haiku-* 或 claude-fable-* 模型名。");
        }

        var settings = JsonFiles.ReadObject(_paths.ClaudeCodeSettings, "Claude Code settings.json");
        if (settings["env"] is not null and not JsonObject)
        {
            throw RelayMateException.InvalidConfiguration("Claude Code 的 env 字段必须是对象。");
        }
        var environment = settings["env"] as JsonObject ?? [];
        environment["ANTHROPIC_BASE_URL"] = RuntimeBaseUrl(configuration.BaseUrl);
        environment["ANTHROPIC_AUTH_TOKEN"] = configuration.ApiKey;
        environment.Remove("ANTHROPIC_API_KEY");
        environment["ANTHROPIC_MODEL"] = configuration.Model;
        settings["env"] = environment;

        JsonFiles.WriteObject(settings, _paths.ClaudeCodeSettings);
        WriteDeploymentMode(_paths.ClaudeDesktopConfig);
        WriteDeploymentMode(_paths.ClaudeThirdPartyConfig);
        WriteDesktopProfile(configuration, enabledModels);
        SelectDesktopProfile();
    }

    public static string RuntimeBaseUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return value;
        }
        var path = uri.AbsolutePath.TrimEnd('/');
        if (path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase))
        {
            path = path[..^3];
        }
        var builder = new UriBuilder(uri) { Path = path };
        return builder.Uri.AbsoluteUri.TrimEnd('/');
    }

    public static bool IsClaudeDesktopModelId(string value)
    {
        var model = value.Trim().ToLowerInvariant();
        var route = model.StartsWith("anthropic/claude-", StringComparison.Ordinal)
            ? model["anthropic/claude-".Length..]
            : model.StartsWith("claude-", StringComparison.Ordinal)
                ? model["claude-".Length..]
                : string.Empty;
        return new[] { "sonnet-", "opus-", "haiku-", "fable-" }
            .Any(prefix => route.StartsWith(prefix, StringComparison.Ordinal));
    }

    private RelayConfiguration? ReadDesktopConfiguration()
    {
        if (!File.Exists(_paths.ClaudeProfile))
        {
            return null;
        }

        var profile = JsonFiles.ReadObject(_paths.ClaudeProfile, "Claude 桌面网关配置");
        var baseUrl = JsonFiles.String(profile, "inferenceGatewayBaseUrl");
        var key = JsonFiles.String(profile, "inferenceGatewayApiKey");
        if (baseUrl is null || key is null || profile["inferenceModels"] is not JsonArray models)
        {
            return null;
        }

        var parsed = new List<string>();
        var oneMillion = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in models)
        {
            if (item is JsonValue value && value.TryGetValue<string>(out var name))
            {
                parsed.Add(name);
            }
            else if (item is JsonObject model)
            {
                var modelName = JsonFiles.String(model, "name") ?? JsonFiles.String(model, "id");
                if (modelName is null)
                {
                    continue;
                }
                parsed.Add(modelName);
                if (JsonFiles.Bool(model, "supports1m"))
                {
                    oneMillion.Add(modelName);
                }
            }
        }

        return parsed.Count == 0
            ? null
            : new RelayConfiguration(baseUrl, parsed[0], key, parsed, oneMillion);
    }

    private bool DesktopUsesThirdPartyDeployment()
    {
        foreach (var path in new[] { _paths.ClaudeDesktopConfig, _paths.ClaudeThirdPartyConfig })
        {
            if (File.Exists(path) && JsonFiles.String(JsonFiles.ReadObject(path, "Claude 桌面配置"), "deploymentMode") == "3p")
            {
                return true;
            }
        }
        return File.Exists(_paths.ClaudeMeta)
            && JsonFiles.String(JsonFiles.ReadObject(_paths.ClaudeMeta, "Claude 桌面配置索引"), "appliedId") is not null;
    }

    private static void WriteDeploymentMode(string path)
    {
        var root = JsonFiles.ReadObject(path, "Claude 桌面配置");
        root["deploymentMode"] = "3p";
        JsonFiles.WriteObject(root, path);
    }

    private void WriteDesktopProfile(RelayConfiguration configuration, IReadOnlyList<string> enabledModels)
    {
        var ordered = new[] { configuration.Model }
            .Concat(enabledModels.Where(model => model != configuration.Model));
        var models = new JsonArray();
        foreach (var model in ordered)
        {
            if (configuration.OneMillionContextModels?.Contains(model) == true)
            {
                models.Add(new JsonObject { ["name"] = model, ["supports1m"] = true });
            }
            else
            {
                models.Add(model);
            }
        }

        var profile = new JsonObject
        {
            ["coworkEgressAllowedHosts"] = new JsonArray("*"),
            ["disableDeploymentModeChooser"] = true,
            ["inferenceGatewayApiKey"] = configuration.ApiKey,
            ["inferenceGatewayAuthScheme"] = "bearer",
            ["inferenceGatewayBaseUrl"] = RuntimeBaseUrl(configuration.BaseUrl),
            ["inferenceModels"] = models,
            ["inferenceProvider"] = "gateway"
        };
        JsonFiles.WriteObject(profile, _paths.ClaudeProfile);
    }

    private void SelectDesktopProfile()
    {
        var meta = JsonFiles.ReadObject(_paths.ClaudeMeta, "Claude 桌面配置索引");
        var entries = meta["entries"] as JsonArray ?? [];
        var retained = entries
            .Where(item => item is not JsonObject entry
                || !string.Equals(JsonFiles.String(entry, "id"), DesktopProfileId, StringComparison.OrdinalIgnoreCase))
            .Select(item => item?.DeepClone())
            .ToList();
        retained.Add(new JsonObject { ["id"] = DesktopProfileId, ["name"] = "RelayMate" });
        meta["entries"] = new JsonArray(retained.ToArray());
        meta["appliedId"] = DesktopProfileId;
        JsonFiles.WriteObject(meta, _paths.ClaudeMeta);
    }
}
