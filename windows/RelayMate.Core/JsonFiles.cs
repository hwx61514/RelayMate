using System.Globalization;
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
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw RelayMateException.InvalidConfiguration($"{context} 无法读取：{exception.Message}");
        }
    }

    public static void WriteObject(JsonObject value, string path)
    {
        var json = value.ToJsonString(Options) + Environment.NewLine;
        SecureFileSystem.Write(System.Text.Encoding.UTF8.GetBytes(json), path);
    }

    // Relays are inconsistent about these field types, so a mismatch degrades to the
    // default instead of throwing. GetValue<T> raises InvalidOperationException — not
    // JsonException — when the node holds another type, which no caller expects.
    // Both switch on GetValueKind rather than TryGetValue<T>, because TryGetValue only
    // converts for JsonElement-backed nodes: on a node built in memory from an int it
    // demands the exact CLR type, so a numeric check written as TryGetValue<double>
    // passes against parsed JSON and fails against a constructed JsonObject.
    public static string? String(JsonObject? value, string key) =>
        value?[key] is JsonValue node && node.GetValueKind() == JsonValueKind.String
            ? node.GetValue<string>()
            : null;

    public static bool Bool(JsonObject? value, string key)
    {
        if (value?[key] is not JsonValue node)
        {
            return false;
        }
        switch (node.GetValueKind())
        {
            case JsonValueKind.True:
                return true;
            case JsonValueKind.Number:
                return double.TryParse(
                    node.ToJsonString(),
                    NumberStyles.Float,
                    CultureInfo.InvariantCulture,
                    out var number) && number != 0;
            case JsonValueKind.String:
                var text = node.GetValue<string>();
                return string.Equals(text, "true", StringComparison.OrdinalIgnoreCase) || text == "1";
            default:
                return false;
        }
    }
}
