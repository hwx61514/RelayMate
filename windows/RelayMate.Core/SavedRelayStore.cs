using System.Text.Json;

namespace RelayMate.Core;

/// <summary>
/// Persistence for the saved relay list. No shell constructs this yet — the Windows
/// window has no saved-relay UI — so it is groundwork, not a shipped feature. The
/// README documents the gap; wire this up when that UI lands.
/// </summary>
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
