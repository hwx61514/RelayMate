using System.Text;
using System.Text.Json.Nodes;
using RelayMate.Core;

var tests = new (string Name, Action Body)[]
{
    ("Windows paths use USERPROFILE and LOCALAPPDATA roots", TestWindowsPaths),
    ("Claude apply preserves unrelated JSON", TestClaudeApply),
    ("Codex apply preserves unrelated TOML", TestCodexApply),
    ("Backup detects drift and restores exact bytes", TestBackupRestore),
    ("Model catalog parses common shapes", TestModelParsing),
    ("TOML top-level updates do not overwrite tables", TestTomlEditing),
    ("Mistyped JSON fields degrade instead of throwing", TestJsonFieldTypeTolerance),
    ("Endpoint paths are not appended twice", TestEndpointUriIdempotence),
    ("Windows app and packaging declare x86 RID", TestX86ProjectConfiguration)
};

var failures = 0;
foreach (var test in tests)
{
    try
    {
        test.Body();
        Console.WriteLine($"PASS {test.Name}");
    }
    catch (Exception exception)
    {
        failures++;
        Console.Error.WriteLine($"FAIL {test.Name}: {exception}");
    }
}

Console.WriteLine($"Executed {tests.Length} tests, {failures} failures.");
return failures == 0 ? 0 : 1;

static void TestWindowsPaths()
{
    using var temp = TempDirectory.Create();
    var paths = NewPaths(temp.Path);
    Equal(Path.Combine(temp.Path, "home", ".claude", "settings.json"), paths.ClaudeCodeSettings);
    Equal(Path.Combine(temp.Path, "local", "Claude", "claude_desktop_config.json"), paths.ClaudeDesktopConfig);
    Equal(Path.Combine(temp.Path, "home", ".codex", "config.toml"), paths.CodexConfig);
}

static void TestClaudeApply()
{
    using var temp = TempDirectory.Create();
    var paths = NewPaths(temp.Path);
    Directory.CreateDirectory(Path.GetDirectoryName(paths.ClaudeCodeSettings)!);
    File.WriteAllText(paths.ClaudeCodeSettings, "{\"env\":{\"KEEP\":\"yes\",\"ANTHROPIC_API_KEY\":\"old\"},\"permissions\":{\"allow\":[\"Read\"]}}", Encoding.UTF8);
    var adapter = new ClaudeConfigurationAdapter(paths);
    adapter.Apply(new RelayConfiguration(
        "https://relay.example.com/v1",
        "claude-sonnet-4-5",
        "secret",
        ["claude-sonnet-4-5", "claude-opus-4-1"],
        new HashSet<string> { "claude-sonnet-4-5" }));

    var settings = JsonNode.Parse(File.ReadAllBytes(paths.ClaudeCodeSettings))!.AsObject();
    var environment = settings["env"]!.AsObject();
    Equal("yes", environment["KEEP"]!.GetValue<string>());
    Equal("https://relay.example.com", environment["ANTHROPIC_BASE_URL"]!.GetValue<string>());
    Equal("secret", environment["ANTHROPIC_AUTH_TOKEN"]!.GetValue<string>());
    True(environment["ANTHROPIC_API_KEY"] is null);
    Equal("Read", settings["permissions"]!["allow"]![0]!.GetValue<string>());

    var profile = JsonNode.Parse(File.ReadAllBytes(paths.ClaudeProfile))!.AsObject();
    Equal("gateway", profile["inferenceProvider"]!.GetValue<string>());
    True(profile["inferenceModels"]![0]!["supports1m"]!.GetValue<bool>());
    Equal("3p", JsonNode.Parse(File.ReadAllBytes(paths.ClaudeDesktopConfig))!["deploymentMode"]!.GetValue<string>());
}

static void TestCodexApply()
{
    using var temp = TempDirectory.Create();
    var paths = NewPaths(temp.Path);
    Directory.CreateDirectory(paths.CodexDirectory);
    File.WriteAllText(paths.CodexConfig, "# keep comment\napproval_policy = \"on-request\"\n\n[mcp_servers.demo]\ncommand = \"demo\"\n", Encoding.UTF8);
    var adapter = new CodexConfigurationAdapter(paths);
    adapter.Apply(new RelayConfiguration(
        "https://relay.example.com/v1",
        "gpt-test",
        "secret",
        ["gpt-test", "gpt-second"]));

    var text = File.ReadAllText(paths.CodexConfig, Encoding.UTF8);
    Contains("# keep comment", text);
    Contains("approval_policy = \"on-request\"", text);
    Contains("[mcp_servers.demo]", text);
    Contains("model = \"gpt-test\"", text);
    Contains("model_provider = \"relay-setup\"", text);
    Contains("[model_providers.relay-setup]", text);
    Contains("wire_api = \"responses\"", text);

    var current = adapter.CurrentConfiguration() ?? throw new Exception("Expected current Codex configuration.");
    Equal("gpt-test", current.Model);
    Equal(2, current.EffectiveEnabledModels.Count);
    var catalog = JsonNode.Parse(File.ReadAllBytes(paths.CodexCatalog))!.AsObject();
    Equal("gpt-test", catalog["models"]![0]!["slug"]!.GetValue<string>());
}

static void TestBackupRestore()
{
    using var temp = TempDirectory.Create();
    var support = Path.Combine(temp.Path, "support");
    var target = Path.Combine(temp.Path, "config", "settings.json");
    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
    var original = Encoding.UTF8.GetBytes("{\"original\":true}\n");
    File.WriteAllBytes(target, original);
    var store = new BackupStore(support);
    store.EnsureBaseline(ClientKind.Claude, [target]);
    SecureFileSystem.Write(Encoding.UTF8.GetBytes("{\"managed\":true}\n"), target);
    store.MarkApplied(ClientKind.Claude, [target]);
    Equal(ConfigurationStatus.Configured, store.Status(ClientKind.Claude));
    File.WriteAllText(target, "external", Encoding.UTF8);
    Equal(ConfigurationStatus.Changed, store.Status(ClientKind.Claude));
    Throws<RelayMateException>(() => store.Restore(ClientKind.Claude, false));
    store.Restore(ClientKind.Claude, true);
    True(File.ReadAllBytes(target).SequenceEqual(original));
}

static void TestModelParsing()
{
    var data = Encoding.UTF8.GetBytes("{\"data\":[{\"id\":\"gpt-b\"},{\"id\":\"gpt-a\",\"supports1m\":true},\"gpt-c\"]}");
    var catalog = ConnectivityTester.ParseModels(data);
    Equal("gpt-a,gpt-b,gpt-c", string.Join(',', catalog.Models));
    True(catalog.OneMillionContextModels.Contains("gpt-a"));
}

static void TestTomlEditing()
{
    const string original = "model = \"old\"\n\n[profiles.demo]\nmodel = \"nested\"\n";
    var updated = TomlText.SetTopLevelString("model", "new", original);
    Equal("new", TomlText.TopLevelValue("model", updated));
    Equal("nested", TomlText.Value("model", TomlText.Table("profiles.demo", updated)!));
}

static void TestX86ProjectConfiguration()
{
    var root = FindRepositoryRoot();
    var project = File.ReadAllText(Path.Combine(root, "windows", "RelayMate.Windows", "RelayMate.Windows.csproj"));
    Contains("<Platforms>x86;x64</Platforms>", project);
    Contains("<RuntimeIdentifier Condition=\"'$(Platform)' == 'x86'\">win-x86</RuntimeIdentifier>", project);
    Contains("<AssemblyName Condition=\"'$(RelayMateExecutableName)' != ''\">$(RelayMateExecutableName)</AssemblyName>", project);
    var profile = File.ReadAllText(Path.Combine(root, "windows", "RelayMate.Windows", "Properties", "PublishProfiles", "win-x86.pubxml"));
    Contains("<RuntimeIdentifier>win-x86</RuntimeIdentifier>", profile);
    var appXaml = File.ReadAllText(Path.Combine(root, "windows", "RelayMate.Windows", "App.xaml"));
    Contains("<XamlControlsResources xmlns=\"using:Microsoft.UI.Xaml.Controls\" />", appXaml);
    var entryPoint = File.ReadAllText(Path.Combine(root, "windows", "RelayMate.Windows", "Program.cs"));
    Contains("MICROSOFT_WINDOWSAPPRUNTIME_BASE_DIRECTORY", entryPoint);
    Contains("ComWrappersSupport.InitializeComWrappers", entryPoint);
    Contains("Application.Start", entryPoint);
    var packageScript = File.ReadAllText(Path.Combine(root, "scripts", "package-windows.ps1"));
    Contains("--runtime $runtime", packageScript);
    Contains("--property:RelayMateExecutableName=$assemblyName", packageScript);
    Contains("--property:PublishSingleFile=true", packageScript);
    Contains("$publishedExecutable = Join-Path $output \"$assemblyName.exe\"", packageScript);
    Contains("RelayMate-Windows-$Architecture.exe", packageScript);
    Contains("verify-pe-x86.ps1", packageScript);
    Contains("if ($LASTEXITCODE -ne 0)", packageScript);
    var verifier = File.ReadAllText(Path.Combine(root, "scripts", "verify-pe-x86.ps1"));
    Contains("0x014C", verifier);
}

static void TestJsonFieldTypeTolerance()
{
    var value = new JsonObject
    {
        ["id"] = "relay-model",
        ["name"] = 42,
        ["supports1m"] = 1,
        ["supports_1m"] = "false"
    };
    True(JsonFiles.String(value, "id") == "relay-model");
    True(JsonFiles.String(value, "name") is null);
    True(JsonFiles.String(value, "missing") is null);
    True(JsonFiles.Bool(value, "supports1m"));
    True(!JsonFiles.Bool(value, "supports_1m"));
    True(!JsonFiles.Bool(value, "missing"));

    // The same object parsed from text is backed differently; both must behave alike.
    var parsed = JsonNode.Parse("""{"id":"relay-model","name":42,"supports1m":1,"supports_1m":"false"}""")!.AsObject();
    True(JsonFiles.String(parsed, "id") == "relay-model");
    True(JsonFiles.String(parsed, "name") is null);
    True(JsonFiles.Bool(parsed, "supports1m"));
    True(!JsonFiles.Bool(parsed, "supports_1m"));

    var catalog = ConnectivityTester.ParseModels(
        Encoding.UTF8.GetBytes("""{"data":[{"id":"a","supports1m":1},{"id":"b","supports1m":0}]}"""));
    Equal(2, catalog.Models.Count);
    True(catalog.OneMillionContextModels.Contains("a"));
    True(!catalog.OneMillionContextModels.Contains("b"));
}

static void TestEndpointUriIdempotence()
{
    Equal(
        "https://relay.example.com/v1/responses",
        ConnectivityTester.EndpointUri(new Uri("https://relay.example.com/v1/responses"), ClientKind.Codex, false).ToString());
    Equal(
        "https://relay.example.com/v1/responses",
        ConnectivityTester.EndpointUri(new Uri("https://relay.example.com/v1"), ClientKind.Codex, false).ToString());
    Equal(
        "https://relay.example.com/v1/responses",
        ConnectivityTester.EndpointUri(new Uri("https://relay.example.com"), ClientKind.Codex, false).ToString());
    Equal(
        "https://relay.example.com/v1/chat/completions",
        ConnectivityTester.EndpointUri(new Uri("https://relay.example.com/v1/chat/completions"), ClientKind.Codex, true).ToString());
    Equal(
        "https://relay.example.com/v1/messages",
        ConnectivityTester.EndpointUri(new Uri("https://relay.example.com/v1/messages"), ClientKind.Claude, false).ToString());
    Equal(
        "https://relay.example.com/v1/messages",
        ConnectivityTester.EndpointUri(new Uri("https://relay.example.com/v1"), ClientKind.Claude, false).ToString());
}

// codexHome must be passed explicitly: omitting it falls back to the real CODEX_HOME
// environment variable, and the Codex tests would then rewrite the developer's own config.
static WindowsRelayMatePaths NewPaths(string root) => new(
    Path.Combine(root, "home"),
    Path.Combine(root, "local"),
    Path.Combine(root, "support"),
    Path.Combine(root, "home", ".codex"));

static string FindRepositoryRoot()
{
    var directory = new DirectoryInfo(AppContext.BaseDirectory);
    while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "Package.swift")))
    {
        directory = directory.Parent;
    }
    return directory?.FullName ?? throw new Exception("Repository root not found.");
}

static void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new Exception($"Expected {expected}, got {actual}.");
    }
}

static void True(bool value)
{
    if (!value)
    {
        throw new Exception("Expected true.");
    }
}

static void Contains(string expected, string actual)
{
    if (!actual.Contains(expected, StringComparison.Ordinal))
    {
        throw new Exception($"Expected text to contain: {expected}\nActual:\n{actual}");
    }
}

static void Throws<T>(Action action) where T : Exception
{
    try
    {
        action();
    }
    catch (T)
    {
        return;
    }
    throw new Exception($"Expected {typeof(T).Name}.");
}

sealed class TempDirectory : IDisposable
{
    private TempDirectory(string path)
    {
        Path = path;
        Directory.CreateDirectory(path);
    }

    public string Path { get; }
    public static TempDirectory Create() => new(System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"relaymate-{Guid.NewGuid():N}"));

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, true);
        }
        catch
        {
            // Test cleanup is best effort.
        }
    }
}
