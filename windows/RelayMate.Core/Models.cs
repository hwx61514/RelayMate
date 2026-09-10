using System.Text.Json.Serialization;

namespace RelayMate.Core;

[JsonConverter(typeof(JsonStringEnumConverter<ClientKind>))]
public enum ClientKind
{
    Claude,
    Codex
}

public enum ConfigurationStatus
{
    NotConfigured,
    External,
    Configured,
    Changed,
    Invalid
}

public sealed record RelayConfiguration(
    string BaseUrl,
    string Model,
    string ApiKey,
    IReadOnlyList<string>? EnabledModels = null,
    IReadOnlySet<string>? OneMillionContextModels = null,
    IReadOnlyList<string>? CodexRedirectedProviders = null)
{
    public IReadOnlyList<string> EffectiveEnabledModels =>
        EnabledModels is { Count: > 0 } ? EnabledModels : [Model];

    public RelayConfiguration Normalize()
    {
        var model = Model.Trim();
        var models = (EnabledModels ?? [])
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        if (models.Count == 0 && model.Length > 0)
        {
            models.Add(model);
        }

        var oneMillion = new HashSet<string>(
            OneMillionContextModels ?? new HashSet<string>(),
            StringComparer.Ordinal);
        oneMillion.IntersectWith(models);

        var providers = (CodexRedirectedProviders ?? [])
            .Select(value => value.Trim())
            .Where(value => value.Length > 0 && value != CodexConfigurationAdapter.ProfileName)
            .Distinct(StringComparer.Ordinal)
            .ToList();

        return this with
        {
            BaseUrl = BaseUrl.Trim(),
            Model = model,
            ApiKey = ApiKey.Trim(),
            EnabledModels = models,
            OneMillionContextModels = oneMillion,
            CodexRedirectedProviders = providers
        };
    }
}

public sealed record ModelCatalog(
    IReadOnlyList<string> Models,
    IReadOnlySet<string> OneMillionContextModels);

public sealed record SavedClientConfiguration(
    string Model,
    IReadOnlyList<string> EnabledModels,
    IReadOnlySet<string> OneMillionContextModels);

public sealed record SavedRelayProfile(
    Guid Id,
    string Name,
    string BaseUrl,
    string ApiKey,
    IReadOnlyDictionary<ClientKind, SavedClientConfiguration> Clients,
    DateTimeOffset UpdatedAt);

public sealed class RelayMateException(string message) : Exception(message)
{
    public static RelayMateException InvalidUrl() => new("请输入完整的中转站 URL。");
    public static RelayMateException InsecureUrl() => new("远程中转站必须使用 HTTPS。");
    public static RelayMateException MissingModel() => new("请选择默认模型。");
    public static RelayMateException MissingApiKey() => new("请输入 API Key。");
    public static RelayMateException InvalidConfiguration(string message) => new($"现有配置无法安全修改：{message}");
    public static RelayMateException Network(string message) => new($"无法连接中转站：{message}");
    public static RelayMateException Incompatible(string message) => new($"中转站不兼容：{message}");
    public static RelayMateException File(string message) => new($"配置文件操作失败：{message}");
    public static RelayMateException NoBackup() => new("没有找到可还原的原始配置。");
    public static RelayMateException RestoreConflict() => new("配置文件在应用后被其他程序修改。继续还原会覆盖这些变化。");
}
