using System.Text.Json;

namespace RelayMate.Core;

public sealed class SavedRelayStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly string _path;

    public SavedRelayStore(string supportDirectory)
    {
        _path = Path.Combine(supportDirectory, "saved-relays.json");
    }

    public IReadOnlyList<SavedRelayProfile> Load()
    {
        if (!File.Exists(_path))
        {
            return [];
        }
        try
        {
            return JsonSerializer.Deserialize<List<SavedRelayProfile>>(File.ReadAllBytes(_path), Options) ?? [];
        }
        catch (JsonException exception)
        {
            throw RelayMateException.File($"已保存的平台资料损坏：{exception.Message}");
        }
    }

    public void Save(IReadOnlyList<SavedRelayProfile> profiles) =>
        SecureFileSystem.Write(JsonSerializer.SerializeToUtf8Bytes(profiles, Options), _path);
}
