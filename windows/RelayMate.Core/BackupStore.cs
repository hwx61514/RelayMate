using System.Text.Json;

namespace RelayMate.Core;

public sealed record BackupRecord(
    int Version,
    ClientKind Client,
    DateTimeOffset CreatedAt,
    List<FileSnapshot> Originals,
    Dictionary<string, string> AppliedHashes);

public sealed class BackupStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public BackupStore(string directory)
    {
        Directory = directory;
    }

    public string Directory { get; }

    public BackupRecord? Record(ClientKind client)
    {
        var path = RecordPath(client);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<BackupRecord>(File.ReadAllBytes(path), JsonOptions)
                ?? throw RelayMateException.File("备份记录为空。");
        }
        catch (JsonException exception)
        {
            throw RelayMateException.File($"备份记录损坏：{exception.Message}");
        }
    }

    public void EnsureBaseline(ClientKind client, IEnumerable<string> paths)
    {
        var existing = Record(client);
        if (existing is not null)
        {
            var recorded = existing.Originals.Select(item => item.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var path in paths.Where(path => !recorded.Contains(path)))
            {
                existing.Originals.Add(SecureFileSystem.Snapshot(path));
            }
            Save(existing);
            return;
        }

        Save(new BackupRecord(
            1,
            client,
            DateTimeOffset.UtcNow,
            paths.Select(SecureFileSystem.Snapshot).ToList(),
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)));
    }

    public void MarkApplied(ClientKind client, IEnumerable<string> paths)
    {
        var record = Record(client) ?? throw RelayMateException.NoBackup();
        record.AppliedHashes.Clear();
        foreach (var path in paths)
        {
            record.AppliedHashes[path] = SecureFileSystem.Hash(path);
        }
        Save(record);
    }

    public ConfigurationStatus Status(ClientKind client)
    {
        var record = Record(client);
        if (record is null || record.AppliedHashes.Count == 0)
        {
            return ConfigurationStatus.NotConfigured;
        }

        return record.AppliedHashes.Any(item => SecureFileSystem.Hash(item.Key) != item.Value)
            ? ConfigurationStatus.Changed
            : ConfigurationStatus.Configured;
    }

    public void Restore(ClientKind client, bool force)
    {
        var record = Record(client) ?? throw RelayMateException.NoBackup();
        if (!force && Status(client) == ConfigurationStatus.Changed)
        {
            throw RelayMateException.RestoreConflict();
        }

        foreach (var snapshot in record.Originals.AsEnumerable().Reverse())
        {
            SecureFileSystem.Restore(snapshot);
        }
        File.Delete(RecordPath(client));
    }

    private void Save(BackupRecord record)
    {
        SecureFileSystem.Write(JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions), RecordPath(record.Client));
    }

    private string RecordPath(ClientKind client) =>
        Path.Combine(Directory, $"{client.ToString().ToLowerInvariant()}-backup.json");
}
