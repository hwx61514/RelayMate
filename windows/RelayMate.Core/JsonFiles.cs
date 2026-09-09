using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text;

namespace RelayMate.Core;

internal static class JsonFiles
{
    internal static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static JsonObject ReadObject(string path, string context)
    {
        if (!File.Exists(path))
        {
            return [];
        }

        try
        {
            return JsonNode.Parse(File.ReadAllText(path, Encoding.UTF8).TrimStart('\uFEFF')) as JsonObject
                ?? throw RelayMateException.InvalidConfiguration($"{context} 顶层必须是对象。");
        }
        catch (JsonException exception)
        {
            throw RelayMateException.InvalidConfiguration($"{context} 不是有效 JSON：{exception.Message}");
        }
    }

    public static void WriteObject(JsonObject value, string path)
    {
        var json = value.ToJsonString(Options) + Environment.NewLine;
        SecureFileSystem.Write(System.Text.Encoding.UTF8.GetBytes(json), path);
    }

    public static string? String(JsonObject? value, string key) =>
        value?[key]?.GetValue<string>();

    public static bool Bool(JsonObject? value, string key) =>
        value?[key]?.GetValue<bool>() == true;
}
