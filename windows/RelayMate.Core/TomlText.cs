using System.Text;

namespace RelayMate.Core;

public static class TomlText
{
    public static string SetTopLevelString(string key, string value, string text)
    {
        var lines = Lines(text);
        var matches = new List<int>();
        var insideTable = false;
        for (var index = 0; index < lines.Count; index++)
        {
            var trimmed = lines[index].TrimStart();
            if (trimmed.StartsWith("[", StringComparison.Ordinal))
            {
                insideTable = true;
            }
            if (!insideTable && IsAssignment(lines[index], key))
            {
                matches.Add(index);
            }
        }
        if (matches.Count > 1)
        {
            throw RelayMateException.InvalidConfiguration($"Codex config.toml 包含重复的顶层 {key} 字段。");
        }

        var assignment = $"{key} = {Quote(value)}";
        if (matches.Count == 1)
        {
            lines[matches[0]] = assignment;
        }
        else
        {
            var tableIndex = lines.FindIndex(line => line.TrimStart().StartsWith("[", StringComparison.Ordinal));
            if (tableIndex >= 0)
            {
                lines.Insert(tableIndex, assignment);
                lines.Insert(tableIndex + 1, string.Empty);
            }
            else
            {
                TrimEmptyEnd(lines);
                if (lines.Count > 0)
                {
                    lines.Add(string.Empty);
                }
                lines.Add(assignment);
            }
        }
        return Finish(lines);
    }

    public static string RemoveTopLevelString(string key, string value, string text)
    {
        var lines = Lines(text);
        var matches = new List<int>();
        var insideTable = false;
        for (var index = 0; index < lines.Count; index++)
        {
            var trimmed = lines[index].TrimStart();
            if (trimmed.StartsWith("[", StringComparison.Ordinal))
            {
                insideTable = true;
            }
            if (!insideTable && IsAssignment(lines[index], key))
            {
                matches.Add(index);
            }
        }
        if (matches.Count > 1)
        {
            throw RelayMateException.InvalidConfiguration($"Codex config.toml 包含重复的顶层 {key} 字段。");
        }
        if (matches.Count == 1 && TopLevelValue(key, text) == value)
        {
            lines.RemoveAt(matches[0]);
        }
        return Finish(lines);
    }

    public static string? Value(string key, string text)
    {
        foreach (var line in Lines(text).Where(line => IsAssignment(line, key)))
        {
            var equals = line.IndexOf('=');
            if (equals >= 0)
            {
                return Unquote(line[(equals + 1)..].Trim());
            }
        }
        return null;
    }

    public static string? TopLevelValue(string key, string text)
    {
        var insideTable = false;
        foreach (var line in Lines(text))
        {
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith("[", StringComparison.Ordinal))
            {
                insideTable = true;
            }
            if (!insideTable && IsAssignment(line, key))
            {
                var equals = line.IndexOf('=');
                return equals < 0 ? null : Unquote(line[(equals + 1)..].Trim());
            }
        }
        return null;
    }

    public static string? Table(string name, string text)
    {
        var lines = Lines(text);
        var header = $"[{name}]";
        var start = lines.FindIndex(line => line.Trim() == header);
        if (start < 0)
        {
            return null;
        }
        var end = lines.FindIndex(start + 1, line => line.TrimStart().StartsWith("[", StringComparison.Ordinal));
        if (end < 0)
        {
            end = lines.Count;
        }
        return string.Join('\n', lines.Skip(start + 1).Take(end - start - 1));
    }

    public static IReadOnlyList<string> TableNames(string prefix, string text)
    {
        var names = new List<string>();
        foreach (var line in Lines(text))
        {
            var trimmed = line.Trim();
            var marker = $"[{prefix}.";
            if (!trimmed.StartsWith(marker, StringComparison.Ordinal) || !trimmed.EndsWith(']'))
            {
                continue;
            }
            var name = trimmed[marker.Length..^1];
            var nested = name.Contains('.', StringComparison.Ordinal) && !name.StartsWith('"');
            if (name.Length > 0 && !nested && !names.Contains(name, StringComparer.Ordinal))
            {
                names.Add(name);
            }
        }
        return names;
    }

    public static string SetTable(string name, string body, string text)
    {
        var lines = Lines(text);
        TrimEmptyEnd(lines);
        var header = $"[{name}]";
        var starts = lines.Select((line, index) => (line, index))
            .Where(item => item.line.Trim() == header)
            .Select(item => item.index)
            .ToList();
        if (starts.Count > 1)
        {
            throw RelayMateException.InvalidConfiguration($"Codex config.toml 包含重复的 {header} 配置段。");
        }

        var replacement = new List<string> { header };
        replacement.AddRange(Lines(body).Where(line => line.Length > 0));
        if (starts.Count == 1)
        {
            var start = starts[0];
            var end = lines.FindIndex(start + 1, line => line.TrimStart().StartsWith("[", StringComparison.Ordinal));
            if (end < 0)
            {
                end = lines.Count;
            }
            replacement.Add(string.Empty);
            lines.RemoveRange(start, end - start);
            lines.InsertRange(start, replacement);
        }
        else
        {
            if (lines.Count > 0)
            {
                lines.Add(string.Empty);
            }
            lines.AddRange(replacement);
        }
        return Finish(lines);
    }

    public static string Quote(string value)
    {
        var output = new StringBuilder(value.Length + 2).Append('"');
        foreach (var character in value)
        {
            output.Append(character switch
            {
                '\\' => "\\\\",
                '"' => "\\\"",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                _ => character.ToString()
            });
        }
        return output.Append('"').ToString();
    }

    private static bool IsAssignment(string line, string key)
    {
        var trimmed = line.TrimStart();
        if (!trimmed.StartsWith(key, StringComparison.Ordinal))
        {
            return false;
        }
        if (trimmed.Length == key.Length)
        {
            return false;
        }
        return trimmed[key.Length] is ' ' or '\t' or '=';
    }

    private static string? Unquote(string value)
    {
        if (value.Length < 2 || value[0] != '"')
        {
            return null;
        }
        var output = new StringBuilder();
        var escaped = false;
        foreach (var character in value.Skip(1))
        {
            if (escaped)
            {
                output.Append(character switch { 'n' => '\n', 'r' => '\r', 't' => '\t', _ => character });
                escaped = false;
            }
            else if (character == '\\')
            {
                escaped = true;
            }
            else if (character == '"')
            {
                return output.ToString();
            }
            else
            {
                output.Append(character);
            }
        }
        return null;
    }

    private static List<string> Lines(string text) =>
        text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n').ToList();

    private static void TrimEmptyEnd(List<string> lines)
    {
        while (lines.Count > 0 && lines[^1].Length == 0)
        {
            lines.RemoveAt(lines.Count - 1);
        }
    }

    private static string Finish(List<string> lines)
    {
        TrimEmptyEnd(lines);
        return lines.Count == 0 ? string.Empty : string.Join('\n', lines) + "\n";
    }
}
