import Foundation
import XCTest
@testable import RelaySetup

final class ConfigurationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testClaudeApplyPreservesUnrelatedSettings() throws {
        let adapter = ClaudeConfigurationAdapter(homeDirectory: temporaryDirectory)
        let original: [String: Any] = [
            "permissions": ["allow": ["Read"]],
            "env": ["KEEP_ME": "yes", "ANTHROPIC_API_KEY": "old-key"]
        ]
        try PrivateFileSystem.write(
            try JSONSerialization.data(withJSONObject: original),
            to: adapter.settingsURL
        )

        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "claude-sonnet-test",
            apiKey: "secret"
        ))

        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: adapter.settingsURL)) as! [String: Any]
        let environment = result["env"] as! [String: String]
        XCTAssertEqual(environment["KEEP_ME"], "yes")
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://relay.example")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "secret")
        XCTAssertNotNil(result["permissions"])
    }

    func testClaudeApplyConfiguresDesktopThirdPartyDeploymentAndRestoresExactly() throws {
        let adapter = ClaudeConfigurationAdapter(homeDirectory: temporaryDirectory)
        let store = BackupStore(directory: temporaryDirectory.appendingPathComponent("backup"))
        let normalOriginal = Data(#"{"deploymentMode":"1p","keep":"normal"}"#.utf8)
        let thirdPartyOriginal = Data(#"{"deploymentMode":"1p","keep":"third-party"}"#.utf8)
        let metaOriginal = Data(#"{"appliedId":"existing","entries":[{"id":"existing","name":"Existing"},{"id":"9B0875B6-24D4-4C87-9B3E-5DF2B9A50D61","name":"Old RelayMate"}]}"#.utf8)
        let legacyProfileOriginal = Data(#"{"legacy":true}"#.utf8)
        try PrivateFileSystem.write(normalOriginal, to: adapter.desktopNormalConfigURL)
        try PrivateFileSystem.write(thirdPartyOriginal, to: adapter.desktopThirdPartyConfigURL)
        try PrivateFileSystem.write(metaOriginal, to: adapter.desktopMetaURL)
        try PrivateFileSystem.write(legacyProfileOriginal, to: adapter.legacyDesktopProfileURL)

        try store.ensureBaseline(for: .claude, paths: adapter.managedPaths)
        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "claude-opus-5",
            apiKey: "secret",
            enabledModels: ["claude-haiku-4-5", "claude-opus-5", "claude-sonnet-4-6"]
        ))
        try store.markApplied(for: .claude, paths: adapter.managedPaths)

        let normal = try JSONSerialization.jsonObject(
            with: Data(contentsOf: adapter.desktopNormalConfigURL)
        ) as! [String: Any]
        let thirdParty = try JSONSerialization.jsonObject(
            with: Data(contentsOf: adapter.desktopThirdPartyConfigURL)
        ) as! [String: Any]
        let profile = try JSONSerialization.jsonObject(
            with: Data(contentsOf: adapter.desktopProfileURL)
        ) as! [String: Any]
        let meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: adapter.desktopMetaURL)
        ) as! [String: Any]

        XCTAssertEqual(normal["deploymentMode"] as? String, "3p")
        XCTAssertEqual(normal["keep"] as? String, "normal")
        XCTAssertEqual(thirdParty["deploymentMode"] as? String, "3p")
        XCTAssertEqual(thirdParty["keep"] as? String, "third-party")
        XCTAssertEqual(profile["inferenceProvider"] as? String, "gateway")
        XCTAssertEqual(profile["inferenceGatewayBaseUrl"] as? String, "https://relay.example")
        XCTAssertEqual(profile["inferenceGatewayApiKey"] as? String, "secret")
        XCTAssertEqual(profile["inferenceGatewayAuthScheme"] as? String, "bearer")
        XCTAssertEqual(
            profile["inferenceModels"] as? [String],
            ["claude-opus-5", "claude-haiku-4-5", "claude-sonnet-4-6"]
        )
        XCTAssertEqual(meta["appliedId"] as? String, ClaudeConfigurationAdapter.desktopProfileID)
        let entries = meta["entries"] as! [[String: Any]]
        XCTAssertTrue(entries.contains { $0["id"] as? String == "existing" })
        XCTAssertFalse(entries.contains {
            $0["id"] as? String == ClaudeConfigurationAdapter.legacyDesktopProfileID
        })
        XCTAssertTrue(entries.contains {
            $0["id"] as? String == ClaudeConfigurationAdapter.desktopProfileID
                && $0["name"] as? String == "RelayMate"
        })
        let appliedProfileNames = try FileManager.default.contentsOfDirectory(
            atPath: adapter.desktopProfileURL.deletingLastPathComponent().path
        )
        XCTAssertTrue(appliedProfileNames.contains(adapter.desktopProfileURL.lastPathComponent))
        XCTAssertFalse(appliedProfileNames.contains(adapter.legacyDesktopProfileURL.lastPathComponent))

        try store.restore(client: .claude, force: false)
        XCTAssertEqual(try Data(contentsOf: adapter.desktopNormalConfigURL), normalOriginal)
        XCTAssertEqual(try Data(contentsOf: adapter.desktopThirdPartyConfigURL), thirdPartyOriginal)
        XCTAssertEqual(try Data(contentsOf: adapter.desktopMetaURL), metaOriginal)
        XCTAssertEqual(try Data(contentsOf: adapter.legacyDesktopProfileURL), legacyProfileOriginal)
        let restoredProfileNames = try FileManager.default.contentsOfDirectory(
            atPath: adapter.desktopProfileURL.deletingLastPathComponent().path
        )
        XCTAssertTrue(restoredProfileNames.contains(adapter.legacyDesktopProfileURL.lastPathComponent))
        XCTAssertFalse(restoredProfileNames.contains(adapter.desktopProfileURL.lastPathComponent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: adapter.settingsURL.path))
    }

    func testClaudeDesktopProfileIDMatchesClaudeValidationRule() throws {
        let regex = try NSRegularExpression(pattern: "^[a-f0-9-]{36}$")
        let id = ClaudeConfigurationAdapter.desktopProfileID
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        XCTAssertNotNil(regex.firstMatch(in: id, range: range))
        XCTAssertEqual(UUID(uuidString: id)?.uuidString.lowercased(), id)
    }

    func testClaudeDesktopModelValidationMatchesSupportedRouteNames() {
        XCTAssertTrue(ClaudeConfigurationAdapter.isClaudeDesktopModelID("claude-sonnet-4-6"))
        XCTAssertTrue(ClaudeConfigurationAdapter.isClaudeDesktopModelID("anthropic/claude-opus-5"))
        XCTAssertFalse(ClaudeConfigurationAdapter.isClaudeDesktopModelID("custom-model"))
        XCTAssertFalse(ClaudeConfigurationAdapter.isClaudeDesktopModelID("claude-test"))
    }

    func testClaudeScanKeepsDesktopAllowlistAndCodeDefault() throws {
        let adapter = ClaudeConfigurationAdapter(homeDirectory: temporaryDirectory)
        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "claude-sonnet-4-6",
            apiKey: "secret",
            enabledModels: ["claude-sonnet-4-6", "claude-opus-5", "claude-haiku-4-5"]
        ))

        let configuration = try XCTUnwrap(adapter.currentConfiguration())
        XCTAssertEqual(configuration.model, "claude-sonnet-4-6")
        XCTAssertEqual(
            configuration.enabledModels,
            ["claude-sonnet-4-6", "claude-opus-5", "claude-haiku-4-5"]
        )
    }

    func testClaudeDesktopProfilePreservesExplicit1MCapability() throws {
        let adapter = ClaudeConfigurationAdapter(homeDirectory: temporaryDirectory)
        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "claude-opus-5",
            apiKey: "secret",
            enabledModels: ["claude-opus-5", "claude-sonnet-4-6", "claude-haiku-4-5"],
            oneMillionContextModels: ["claude-sonnet-4-6", "claude-disabled-1m"]
        ))

        let profile = try JSONSerialization.jsonObject(
            with: Data(contentsOf: adapter.desktopProfileURL)
        ) as! [String: Any]
        let models = profile["inferenceModels"] as! [Any]
        XCTAssertEqual(models[0] as? String, "claude-opus-5")
        XCTAssertEqual(
            models[1] as? [String: AnyHashable],
            ["name": "claude-sonnet-4-6", "supports1m": true]
        )
        XCTAssertEqual(models[2] as? String, "claude-haiku-4-5")

        let configuration = try XCTUnwrap(adapter.currentConfiguration())
        XCTAssertEqual(
            configuration.enabledModels,
            ["claude-opus-5", "claude-sonnet-4-6", "claude-haiku-4-5"]
        )
        XCTAssertEqual(configuration.oneMillionContextModels, ["claude-sonnet-4-6"])
    }

    @MainActor
    func testClaudeEnabledModelSelectionControlsDefaultAndFiltersUnsupportedModels() {
        let viewModel = RelaySetupModel(
            backupStore: BackupStore(directory: temporaryDirectory.appendingPathComponent("support")),
            adapters: [
                .claude: ClaudeConfigurationAdapter(homeDirectory: temporaryDirectory),
                .codex: CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
            ]
        )
        viewModel.select(.claude)
        viewModel.modelOptions = ["claude-opus-5", "claude-sonnet-4-6", "gpt-5"]

        viewModel.enableAllModels(
            viewModel.modelOptions.filter(ClaudeConfigurationAdapter.isClaudeDesktopModelID)
        )
        XCTAssertEqual(viewModel.enabledModels, ["claude-opus-5", "claude-sonnet-4-6"])
        XCTAssertTrue(viewModel.enabledModels.contains(viewModel.model))

        let oldDefault = viewModel.model
        viewModel.toggleEnabledModel(oldDefault)
        XCTAssertFalse(viewModel.enabledModels.contains(oldDefault))
        XCTAssertEqual(viewModel.model, viewModel.enabledModels.sorted().first)

        viewModel.clearEnabledModels()
        XCTAssertTrue(viewModel.enabledModels.isEmpty)
        XCTAssertEqual(viewModel.model, "")
    }

    func testCodexApplyPreservesMainConfigAndWritesActiveProvider() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        let original = """
        # user setting
        model = "old-model"

        [mcp_servers.echo]
        command = "echo"

        """
        try PrivateFileSystem.write(Data(original.utf8), to: adapter.configURL)

        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "gpt-test",
            apiKey: "secret",
            enabledModels: ["gpt-test", "gpt-second"]
        ))

        let main = try String(contentsOf: adapter.configURL, encoding: .utf8)
        XCTAssertTrue(main.contains("# user setting"))
        XCTAssertTrue(main.contains("[mcp_servers.echo]"))
        XCTAssertTrue(main.contains("model = \"gpt-test\""))
        XCTAssertTrue(main.contains("model_provider = \"relay-setup\""))
        XCTAssertTrue(main.contains("model_catalog_json = \"relaymate-model-catalog.json\""))
        XCTAssertTrue(main.contains("[model_providers.relay-setup]"))
        XCTAssertTrue(main.contains("wire_api = \"responses\""))
        XCTAssertTrue(main.contains("experimental_bearer_token = \"secret\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: adapter.profileURL.path))
        XCTAssertEqual(
            try adapter.currentConfiguration(),
            RelayConfiguration(
                baseURL: "https://relay.example/v1",
                model: "gpt-test",
                apiKey: "secret",
                enabledModels: ["gpt-test", "gpt-second"]
            )
        )

        let catalog = try JSONSerialization.jsonObject(
            with: Data(contentsOf: adapter.catalogURL)
        ) as! [String: Any]
        let entries = catalog["models"] as! [[String: Any]]
        XCTAssertEqual(entries.compactMap { $0["slug"] as? String }, ["gpt-test", "gpt-second"])
        XCTAssertTrue(entries.allSatisfy { $0["visibility"] as? String == "list" })
    }

    /// 造一份带既有 provider 的 config.toml，并可选地写几条记着该 provider 的历史会话。
    private func writeCodexFixture(
        adapter: CodexConfigurationAdapter,
        sessions: [String] = []
    ) throws {
        let original = """
        model = "old-model"
        model_provider = "custom"

        [model_providers.custom]
        name = "我的老中转"
        wire_api = "responses"
        requires_openai_auth = true
        base_url = "https://old.example"

        [model_providers.custom.http_headers]
        X-Trace = "on"

        """
        try PrivateFileSystem.write(Data(original.utf8), to: adapter.configURL)

        let day = adapter.sessionsURL.appendingPathComponent("2026/09/08", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for (index, provider) in sessions.enumerated() {
            let meta: [String: Any] = [
                "type": "session_meta",
                "payload": [
                    "session_id": "session-\(index)",
                    "model_provider": provider,
                    "base_instructions": String(repeating: "指令 ", count: 4000)
                ]
            ]
            var line = try JSONSerialization.data(withJSONObject: meta)
            line.append(0x0A)
            try line.write(to: day.appendingPathComponent("rollout-\(index).jsonl"))
        }
    }

    func testLegacyProvidersListUserTablesWithHistoricalSessionCounts() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        try writeCodexFixture(adapter: adapter, sessions: ["custom", "custom", "openai", "relay-setup"])

        XCTAssertEqual(
            adapter.legacyProviders(),
            [LegacyProvider(name: "custom", baseURL: "https://old.example", sessionCount: 2)]
        )
        XCTAssertTrue(
            ClaudeConfigurationAdapter(homeDirectory: temporaryDirectory).legacyProviders().isEmpty
        )
    }

    func testRedirectedProviderPointsLegacySessionsAtTheNewRelay() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        try writeCodexFixture(adapter: adapter)

        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "gpt-test",
            apiKey: "secret",
            enabledModels: ["gpt-test"],
            codexRedirectedProviders: ["custom"]
        ))

        let main = try String(contentsOf: adapter.configURL, encoding: .utf8)
        let custom = try XCTUnwrap(TOMLText.table(named: "model_providers.custom", in: main))
        XCTAssertEqual(TOMLText.value(for: "base_url", in: custom), "https://relay.example/v1")
        XCTAssertEqual(TOMLText.value(for: "experimental_bearer_token", in: custom), "secret")
        XCTAssertEqual(TOMLText.value(for: "name", in: custom), "我的老中转")
        XCTAssertTrue(custom.contains("requires_openai_auth = false"))
        // 新对话仍然走 RelayMate 自己的 provider。
        XCTAssertTrue(main.contains("model_provider = \"relay-setup\""))
        XCTAssertTrue(main.contains("[model_providers.relay-setup]"))
        XCTAssertEqual(
            try adapter.currentConfiguration()?.codexRedirectedProviders,
            ["custom"]
        )
    }

    func testUncheckedLegacyProviderIsLeftUntouched() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        try writeCodexFixture(adapter: adapter)

        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "gpt-test",
            apiKey: "secret",
            enabledModels: ["gpt-test"]
        ))

        let main = try String(contentsOf: adapter.configURL, encoding: .utf8)
        let custom = try XCTUnwrap(TOMLText.table(named: "model_providers.custom", in: main))
        XCTAssertEqual(TOMLText.value(for: "base_url", in: custom), "https://old.example")
        XCTAssertTrue(custom.contains("requires_openai_auth = true"))
        XCTAssertTrue(main.contains("[model_providers.custom.http_headers]"))
        XCTAssertEqual(try adapter.currentConfiguration()?.codexRedirectedProviders, [])
    }

    func testRedirectedProviderRestoresToItsOriginalBytes() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        let store = BackupStore(directory: temporaryDirectory.appendingPathComponent("backup"))
        try writeCodexFixture(adapter: adapter)
        let originalConfig = try Data(contentsOf: adapter.configURL)

        try store.ensureBaseline(for: .codex, paths: adapter.managedPaths)
        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "gpt-test",
            apiKey: "secret",
            enabledModels: ["gpt-test"],
            codexRedirectedProviders: ["custom"]
        ))
        try store.markApplied(for: .codex, paths: adapter.managedPaths)
        try store.restore(client: .codex, force: false)

        XCTAssertEqual(try Data(contentsOf: adapter.configURL), originalConfig)
    }

    @MainActor
    func testWizardChecksLegacyProvidersThatHaveHistoricalSessions() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        try writeCodexFixture(adapter: adapter, sessions: ["custom"])

        let viewModel = RelaySetupModel(
            backupStore: BackupStore(directory: temporaryDirectory.appendingPathComponent("support")),
            tester: ConnectivityTester { _ in throw RelaySetupError.network("unused") },
            adapters: [
                .claude: ClaudeConfigurationAdapter(homeDirectory: temporaryDirectory),
                .codex: adapter
            ]
        )
        viewModel.select(.codex)
        XCTAssertEqual(viewModel.legacyProviders.map(\.name), ["custom"])
        XCTAssertEqual(viewModel.redirectedProviders, ["custom"])

        viewModel.select(.claude)
        XCTAssertTrue(viewModel.legacyProviders.isEmpty)
        XCTAssertTrue(viewModel.redirectedProviders.isEmpty)
    }

    func testCodexCatalogPreservesKnownMetadataAndUsesFallbackForUnknownModel() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "known-model",
            apiKey: "secret",
            enabledModels: ["known-model"]
        ))

        var generated = try JSONSerialization.jsonObject(
            with: Data(contentsOf: adapter.catalogURL)
        ) as! [String: Any]
        var knownEntry = (generated["models"] as! [[String: Any]])[0]
        knownEntry["support_verbosity"] = true
        knownEntry["context_window"] = 999_999
        generated["models"] = [knownEntry]
        try PrivateFileSystem.write(
            try JSONSerialization.data(withJSONObject: generated),
            to: adapter.modelCacheURL
        )

        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "known-model",
            apiKey: "secret",
            enabledModels: ["known-model", "unknown-model"]
        ))

        let catalog = try JSONSerialization.jsonObject(
            with: Data(contentsOf: adapter.catalogURL)
        ) as! [String: Any]
        let entries = catalog["models"] as! [[String: Any]]
        XCTAssertEqual(entries[0]["support_verbosity"] as? Bool, true)
        XCTAssertEqual(entries[0]["context_window"] as? Int, 999_999)
        XCTAssertEqual(entries[1]["support_verbosity"] as? Bool, false)
        XCTAssertNotNil(entries[1]["base_instructions"] as? String)
    }

    func testCodexCatalogAndPointerRestoreExactOriginalBytes() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        let store = BackupStore(directory: temporaryDirectory.appendingPathComponent("backup"))
        let originalConfig = Data("""
        # original
        model = "old-model"
        model_catalog_json = "relaymate-model-catalog.json"

        """.utf8)
        let originalCatalog = Data(#"{"models":[{"slug":"old-model"}]}"#.utf8)
        try PrivateFileSystem.write(originalConfig, to: adapter.configURL)
        try PrivateFileSystem.write(originalCatalog, to: adapter.catalogURL)

        try store.ensureBaseline(for: .codex, paths: adapter.managedPaths)
        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1",
            model: "new-model",
            apiKey: "secret",
            enabledModels: ["new-model", "second-model"]
        ))
        try store.markApplied(for: .codex, paths: adapter.managedPaths)
        try store.restore(client: .codex, force: false)

        XCTAssertEqual(try Data(contentsOf: adapter.configURL), originalConfig)
        XCTAssertEqual(try Data(contentsOf: adapter.catalogURL), originalCatalog)
    }

    func testBackupRestoresOriginalBytesAndMissingFile() throws {
        let store = BackupStore(directory: temporaryDirectory.appendingPathComponent("backup"))
        let existing = temporaryDirectory.appendingPathComponent("existing.json")
        let created = temporaryDirectory.appendingPathComponent("created.toml")
        let original = Data("{\"exact\":true}\n".utf8)
        try PrivateFileSystem.write(original, to: existing)

        try store.ensureBaseline(for: .codex, paths: [existing, created])
        try PrivateFileSystem.write(Data("changed".utf8), to: existing)
        try PrivateFileSystem.write(Data("new".utf8), to: created)
        try store.markApplied(for: .codex, paths: [existing, created])
        try store.restore(client: .codex, force: false)

        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
    }

    func testBackupDetectsExternalDrift() throws {
        let store = BackupStore(directory: temporaryDirectory.appendingPathComponent("backup"))
        let file = temporaryDirectory.appendingPathComponent("config.json")
        try PrivateFileSystem.write(Data("before".utf8), to: file)
        try store.ensureBaseline(for: .claude, paths: [file])
        try PrivateFileSystem.write(Data("applied".utf8), to: file)
        try store.markApplied(for: .claude, paths: [file])
        try PrivateFileSystem.write(Data("external".utf8), to: file)

        XCTAssertEqual(try store.status(for: .claude), .changed)
        XCTAssertThrowsError(try store.restore(client: .claude, force: false)) { error in
            XCTAssertEqual(error as? RelaySetupError, .restoreConflict)
        }
    }

    func testBackupBaselineAddsNewManagedPathsWithoutReplacingOriginals() throws {
        let store = BackupStore(directory: temporaryDirectory.appendingPathComponent("backup"))
        let originalPath = temporaryDirectory.appendingPathComponent("settings.json")
        let addedPath = temporaryDirectory.appendingPathComponent("desktop.json")
        let originalBytes = Data("original".utf8)
        let addedBytes = Data("desktop-before-upgrade".utf8)
        try PrivateFileSystem.write(originalBytes, to: originalPath)
        try store.ensureBaseline(for: .claude, paths: [originalPath])

        try PrivateFileSystem.write(Data("already-applied".utf8), to: originalPath)
        try PrivateFileSystem.write(addedBytes, to: addedPath)
        try store.ensureBaseline(for: .claude, paths: [originalPath, addedPath])
        try PrivateFileSystem.write(Data("new-desktop-config".utf8), to: addedPath)
        try store.markApplied(for: .claude, paths: [originalPath, addedPath])
        try store.restore(client: .claude, force: false)

        XCTAssertEqual(try Data(contentsOf: originalPath), originalBytes)
        XCTAssertEqual(try Data(contentsOf: addedPath), addedBytes)
    }

    func testTOMLTopLevelProfileReplacementLeavesTablesUntouched() throws {
        let input = "profile = \"old\"\n\n[profiles.work]\nprofile = \"nested\"\n"
        let output = try TOMLText.settingTopLevelString(key: "profile", value: "relay-setup", in: input)
        XCTAssertTrue(output.hasPrefix("profile = \"relay-setup\""))
        XCTAssertTrue(output.contains("profile = \"nested\""))
    }

    func testCodexApplyRemovesLegacyRelayProfileSelectorAndFile() throws {
        let adapter = CodexConfigurationAdapter(homeDirectory: temporaryDirectory)
        try PrivateFileSystem.write(
            Data("profile = \"relay-setup\"\n\n[mcp_servers.keep]\ncommand = \"keep\"\n".utf8),
            to: adapter.configURL
        )
        try PrivateFileSystem.write(Data("legacy".utf8), to: adapter.profileURL)

        try adapter.apply(RelayConfiguration(
            baseURL: "https://relay.example/v1", model: "gpt-current", apiKey: "secret"
        ))

        let main = try String(contentsOf: adapter.configURL, encoding: .utf8)
        XCTAssertNil(TOMLText.topLevelValue(for: "profile", in: main))
        XCTAssertTrue(main.contains("[mcp_servers.keep]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: adapter.profileURL.path))
    }

    @MainActor
    func testViewModelScansExternalClaudeRelayWithoutOfferingRestore() throws {
        let home = temporaryDirectory.appendingPathComponent("home")
        let claude = ClaudeConfigurationAdapter(homeDirectory: home)
        let codex = CodexConfigurationAdapter(homeDirectory: home)
        let settings: [String: Any] = [
            "env": [
                "ANTHROPIC_BASE_URL": "https://external.example/v1",
                "ANTHROPIC_API_KEY": "external-key",
                "ANTHROPIC_MODEL": "claude-external"
            ]
        ]
        try PrivateFileSystem.write(
            try JSONSerialization.data(withJSONObject: settings), to: claude.settingsURL
        )

        let viewModel = RelaySetupModel(
            backupStore: BackupStore(directory: temporaryDirectory.appendingPathComponent("support")),
            adapters: [.claude: claude, .codex: codex]
        )

        viewModel.select(.claude)
        XCTAssertEqual(viewModel.selectedStatus, .external)
        XCTAssertFalse(viewModel.canRestoreSelectedClient)
        XCTAssertEqual(viewModel.baseURL, "https://external.example/v1")
        XCTAssertEqual(viewModel.model, "claude-external")
    }

    @MainActor
    func testViewModelReportsMalformedTargetConfiguration() throws {
        let home = temporaryDirectory.appendingPathComponent("home")
        let claude = ClaudeConfigurationAdapter(homeDirectory: home)
        let codex = CodexConfigurationAdapter(homeDirectory: home)
        try PrivateFileSystem.write(Data("not json".utf8), to: claude.settingsURL)

        let viewModel = RelaySetupModel(
            backupStore: BackupStore(directory: temporaryDirectory.appendingPathComponent("support")),
            adapters: [.claude: claude, .codex: codex]
        )

        viewModel.select(.claude)
        XCTAssertEqual(viewModel.selectedStatus, .invalid)
        XCTAssertFalse(viewModel.canRestoreSelectedClient)
    }

    @MainActor
    func testExternalClaudeRelayCanBeReconfiguredAndRestoredExactly() async throws {
        let home = temporaryDirectory.appendingPathComponent("home")
        let claude = ClaudeConfigurationAdapter(homeDirectory: home)
        let codex = CodexConfigurationAdapter(homeDirectory: home)
        let original = Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://old.example","ANTHROPIC_API_KEY":"old-key","ANTHROPIC_MODEL":"old-model"},"theme":"dark"}"#.utf8)
        try PrivateFileSystem.write(original, to: claude.settingsURL)
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("{}".utf8), response)
        }
        let viewModel = RelaySetupModel(
            backupStore: BackupStore(directory: temporaryDirectory.appendingPathComponent("support")),
            tester: tester,
            adapters: [.claude: claude, .codex: codex]
        )

        viewModel.select(.claude)
        XCTAssertEqual(viewModel.selectedStatus, .external)
        XCTAssertFalse(viewModel.canRestoreSelectedClient)
        viewModel.baseURL = "https://new.example/v1"
        viewModel.apiKey = "new-key"
        viewModel.model = "claude-opus-5"
        viewModel.enabledModels = ["claude-opus-5"]
        await viewModel.apply()
        XCTAssertEqual(viewModel.selectedStatus, .configured)
        XCTAssertTrue(viewModel.canRestoreSelectedClient)

        viewModel.requestRestore()
        XCTAssertEqual(try Data(contentsOf: claude.settingsURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.desktopNormalConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.desktopThirdPartyConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.desktopProfileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.desktopProfileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.desktopMetaURL.path))
        XCTAssertEqual(viewModel.selectedStatus, .external)
        XCTAssertFalse(viewModel.canRestoreSelectedClient)
    }

    func testClaudeScanDetectsDesktopThirdPartyDeploymentWithoutReadingAnotherProfile() throws {
        let adapter = ClaudeConfigurationAdapter(homeDirectory: temporaryDirectory)
        try PrivateFileSystem.write(
            Data(#"{"deploymentMode":"3p"}"#.utf8),
            to: adapter.desktopNormalConfigURL
        )

        XCTAssertEqual(
            try adapter.currentConfiguration(),
            RelayConfiguration(baseURL: "", model: "", apiKey: "")
        )
    }

    func testEndpointConstruction() throws {
        let tester = ConnectivityTester()
        let base = try XCTUnwrap(URL(string: "https://relay.example/v1"))
        XCTAssertEqual(
            tester.endpointURL(baseURL: base, client: .claude).absoluteString,
            "https://relay.example/v1/messages"
        )
        XCTAssertEqual(
            tester.endpointURL(baseURL: base, client: .codex).absoluteString,
            "https://relay.example/v1/responses"
        )
        XCTAssertEqual(
            tester.endpointURL(baseURL: base, client: .codex, endpoint: .chatCompletions).absoluteString,
            "https://relay.example/v1/chat/completions"
        )
    }

    func testClaudeRuntimeBaseURLRemovesOnlyTrailingAPIVersion() {
        XCTAssertEqual(
            ClaudeConfigurationAdapter.runtimeBaseURL("https://relay.example/v1"),
            "https://relay.example"
        )
        XCTAssertEqual(
            ClaudeConfigurationAdapter.runtimeBaseURL("https://relay.example/anthropic/v1/"),
            "https://relay.example/anthropic"
        )
        XCTAssertEqual(
            ClaudeConfigurationAdapter.runtimeBaseURL("https://relay.example/api"),
            "https://relay.example/api"
        )
    }

    func testClaudeConnectivityEndpointMatchesRuntimePathConstruction() throws {
        let tester = ConnectivityTester()
        let enteredURL = try XCTUnwrap(URL(string: "https://relay.example/anthropic/v1"))
        let runtimeURL = try XCTUnwrap(URL(string: ClaudeConfigurationAdapter.runtimeBaseURL(enteredURL.absoluteString)))

        XCTAssertEqual(
            tester.endpointURL(baseURL: enteredURL, client: .claude).absoluteString,
            runtimeURL.appendingPathComponent("v1/messages").absoluteString
        )
    }

    func testConnectivityAcceptsSuccessfulResponse() async throws {
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("{}".utf8), response)
        }

        try await tester.validate(
            RelayConfiguration(
                baseURL: "https://relay.example/v1",
                model: "gpt-test",
                apiKey: "secret"
            ),
            for: .codex
        )
    }

    func testConnectivityReportsAuthenticationFailure() async {
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (Data(#"{"error":{"message":"invalid key"}}"#.utf8), response)
        }

        do {
            try await tester.validate(
                RelayConfiguration(
                    baseURL: "https://relay.example",
                    model: "claude-test",
                    apiKey: "bad"
                ),
                for: .claude
            )
            XCTFail("Expected authentication failure")
        } catch let error as RelaySetupError {
            guard case .incompatible(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("API Key"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConnectivityReportsProtocolFailure() async {
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (Data(#"{"error":{"message":"responses unsupported"}}"#.utf8), response)
        }

        do {
            try await tester.validate(
                RelayConfiguration(
                    baseURL: "https://relay.example",
                    model: "gpt-test",
                    apiKey: "key"
                ),
                for: .codex
            )
            XCTFail("Expected protocol failure")
        } catch let error as RelaySetupError {
            guard case .incompatible(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("responses unsupported"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConnectivityReportsUnreachableHost() async {
        let tester = ConnectivityTester { _ in
            throw URLError(.cannotConnectToHost)
        }

        do {
            try await tester.validate(
                RelayConfiguration(
                    baseURL: "https://relay.example",
                    model: "gpt-test",
                    apiKey: "key"
                ),
                for: .codex
            )
            XCTFail("Expected network failure")
        } catch let error as RelaySetupError {
            guard case .network = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemoteHTTPURLIsRejectedBeforeNetworkRequest() async {
        let tester = ConnectivityTester { _ in
            XCTFail("Network request should not run")
            throw URLError(.badURL)
        }

        do {
            try await tester.validate(
                RelayConfiguration(baseURL: "http://relay.example", model: "m", apiKey: "k"),
                for: .codex
            )
            XCTFail("Expected insecure URL failure")
        } catch let error as RelaySetupError {
            XCTAssertEqual(error, .insecureURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testModelCatalogParsesCommonShapesAndSorts() throws {
        let tester = ConnectivityTester()
        let openAI = Data(#"{"data":[{"id":"z-model","supports1m":true},{"id":"a-model"},{"id":"z-model","supports1m":false},"plain-model",{"id":" "}]}"#.utf8)
        let anthropic = Data(#"{"models":[{"name":"claude-b","supports_1m":true},{"id":"claude-a","supports1m":false}]}"#.utf8)

        XCTAssertEqual(
            try tester.parseModels(openAI),
            ModelCatalog(
                models: ["a-model", "plain-model", "z-model"],
                oneMillionContextModels: ["z-model"]
            )
        )
        XCTAssertEqual(
            try tester.parseModels(anthropic),
            ModelCatalog(
                models: ["claude-a", "claude-b"],
                oneMillionContextModels: ["claude-b"]
            )
        )
    }

    @MainActor
    func testClaudeWizardApplies1MCapabilityOnlyToEnabledModels() async throws {
        let home = temporaryDirectory.appendingPathComponent("home")
        let claude = ClaudeConfigurationAdapter(homeDirectory: home)
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.httpMethod == "GET" {
                return (Data(#"{"data":[{"id":"claude-opus-5","supports1m":true},{"id":"claude-sonnet-4-6","supports1m":true}]}"#.utf8), response)
            }
            return (Data("{}".utf8), response)
        }
        let viewModel = RelaySetupModel(
            backupStore: BackupStore(directory: temporaryDirectory.appendingPathComponent("support")),
            tester: tester,
            adapters: [
                .claude: claude,
                .codex: CodexConfigurationAdapter(homeDirectory: home)
            ]
        )

        viewModel.select(.claude)
        viewModel.baseURL = "http://localhost:18991"
        viewModel.apiKey = "test-key"
        await viewModel.loadModels()
        XCTAssertEqual(
            viewModel.oneMillionContextModels,
            ["claude-opus-5", "claude-sonnet-4-6"]
        )

        viewModel.toggleEnabledModel("claude-opus-5")
        await viewModel.apply()

        let configuration = try XCTUnwrap(claude.currentConfiguration())
        XCTAssertEqual(configuration.enabledModels, ["claude-opus-5"])
        XCTAssertEqual(configuration.oneMillionContextModels, ["claude-opus-5"])
    }

    func testModelCatalogRejectsMalformedJSON() {
        let tester = ConnectivityTester()

        XCTAssertThrowsError(try tester.parseModels(Data("not json".utf8))) { error in
            guard case .incompatible(let message) = error as? RelaySetupError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("JSON"))
        }
    }

    func testFetchModelsReportsEmptyCatalog() async {
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(#"{"data":[]}"#.utf8), response)
        }

        do {
            _ = try await tester.fetchModels(baseURL: "https://relay.example/v1", apiKey: "key")
            XCTFail("Expected empty catalog failure")
        } catch let error as RelaySetupError {
            guard case .incompatible(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("为空"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testViewModelFetchApplyAndRestoreCodexFlow() async throws {
        let home = temporaryDirectory.appendingPathComponent("home")
        let codexDirectory = home.appendingPathComponent(".codex")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let original = Data("# keep me\nmodel = \"original\"\n".utf8)
        try PrivateFileSystem.write(original, to: configURL)

        let codex = CodexConfigurationAdapter(homeDirectory: home)
        let claude = ClaudeConfigurationAdapter(homeDirectory: home)
        let store = BackupStore(directory: temporaryDirectory.appendingPathComponent("support"))
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.httpMethod == "GET" {
                return (Data(#"{"data":[{"id":"gpt-b"},{"id":"gpt-a"}]}"#.utf8), response)
            }
            return (Data("{}".utf8), response)
        }
        let viewModel = RelaySetupModel(
            backupStore: store,
            tester: tester,
            adapters: [.claude: claude, .codex: codex]
        )

        viewModel.select(.codex)
        viewModel.baseURL = "http://localhost:18991"
        viewModel.apiKey = "test-key"
        await viewModel.loadModels()
        XCTAssertEqual(viewModel.modelOptions, ["gpt-a", "gpt-b"])
        XCTAssertEqual(viewModel.model, "")
        viewModel.toggleEnabledModel("gpt-a")
        viewModel.toggleEnabledModel("gpt-b")
        viewModel.model = "gpt-b"
        await viewModel.apply()

        XCTAssertEqual(viewModel.selectedStatus, .configured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.profileURL.path))
        XCTAssertEqual(
            try codex.currentConfiguration(),
            RelayConfiguration(
                baseURL: "http://localhost:18991",
                model: "gpt-b",
                apiKey: "test-key",
                enabledModels: ["gpt-b", "gpt-a"]
            )
        )
        viewModel.requestRestore()
        XCTAssertEqual(try Data(contentsOf: configURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.profileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.catalogURL.path))
        XCTAssertEqual(viewModel.selectedStatus, .notConfigured)
    }

    func testTransientGatewayFailureIsRetriedInsteadOfReportedAsIncompatible() async throws {
        let log = RequestLog()
        let tester = ConnectivityTester { request in
            let attempt = log.record(request)
            let status = attempt == 1 ? 554 : 200
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (attempt == 1 ? Data() : Data("{}".utf8), response)
        }

        try await tester.validate(
            RelayConfiguration(baseURL: "https://relay.example/v1", model: "gpt-test", apiKey: "key"),
            for: .codex
        )

        XCTAssertEqual(log.paths, ["/v1/responses", "/v1/responses"])
    }

    func testEmptyErrorBodyStillReportsStatusCode() async {
        let log = RequestLog()
        let tester = ConnectivityTester { request in
            _ = log.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 554, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }

        do {
            try await tester.validate(
                RelayConfiguration(baseURL: "https://relay.example/v1", model: "gpt-test", apiKey: "key"),
                for: .codex
            )
            XCTFail("Expected failure")
        } catch let error as RelaySetupError {
            guard case .incompatible(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("HTTP 554"), message)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(log.paths.count, 2, "网关故障应当重试一次")
    }

    func testChatCompletionsOnlyRelayIsNamedInTheError() async {
        let log = RequestLog()
        let tester = ConnectivityTester { request in
            _ = log.record(request)
            let missing = request.url!.path.hasSuffix("/responses")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: missing ? 404 : 200, httpVersion: nil, headerFields: nil
            )!
            let body = missing ? #"{"error":{"message":"no such endpoint"}}"# : "{}"
            return (Data(body.utf8), response)
        }

        do {
            try await tester.validate(
                RelayConfiguration(baseURL: "https://relay.example/v1", model: "gpt-test", apiKey: "key"),
                for: .codex
            )
            XCTFail("Expected failure")
        } catch let error as RelaySetupError {
            guard case .incompatible(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("只提供 OpenAI Chat Completions"), message)
            XCTAssertTrue(message.contains("wire_api"), message)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(log.paths, ["/v1/responses", "/v1/chat/completions"])
    }

    func testUnreachableRelayReportsTheResponsesFailureNotTheChatOne() async {
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            let body = request.url!.path.hasSuffix("/responses")
                ? #"{"error":{"message":"responses missing"}}"#
                : #"{"error":{"message":"chat missing"}}"#
            return (Data(body.utf8), response)
        }

        do {
            try await tester.validate(
                RelayConfiguration(baseURL: "https://relay.example/v1", model: "gpt-test", apiKey: "key"),
                for: .codex
            )
            XCTFail("Expected failure")
        } catch let error as RelaySetupError {
            guard case .incompatible(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("responses missing"), message)
            XCTAssertFalse(message.contains("chat missing"), message)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCodexDoesNotProbeChatCompletionsOnAuthenticationFailure() async {
        let log = RequestLog()
        let tester = ConnectivityTester { request in
            _ = log.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (Data(#"{"error":{"message":"invalid key"}}"#.utf8), response)
        }

        do {
            try await tester.validate(
                RelayConfiguration(baseURL: "https://relay.example/v1", model: "gpt-test", apiKey: "bad"),
                for: .codex
            )
            XCTFail("Expected authentication failure")
        } catch let error as RelaySetupError {
            guard case .incompatible(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("API Key"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(log.paths, ["/v1/responses"], "鉴权失败不该换端点重试")
    }

    func testSavedRelayStorePersistsMultipleProfilesPrivately() throws {
        let directory = temporaryDirectory.appendingPathComponent("support")
        let store = SavedRelayStore(directory: directory)
        let profiles = [
            SavedRelayProfile(
                id: UUID(),
                name: "常用平台",
                baseURL: "https://first.example/v1",
                apiKey: "first-key",
                clients: [
                    .codex: SavedClientConfiguration(
                        model: "gpt-a",
                        enabledModels: ["gpt-a", "gpt-b"],
                        oneMillionContextModels: []
                    )
                ],
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            SavedRelayProfile(
                id: UUID(),
                name: "备用平台",
                baseURL: "https://second.example/v1",
                apiKey: "second-key",
                clients: [:],
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        ]

        try store.save(profiles)

        XCTAssertEqual(try store.load().map(\.name), ["备用平台", "常用平台"])
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("saved-relays.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    @MainActor
    func testSuccessfulApplySavesAndReloadsRelayProfileForEachClient() async throws {
        let home = temporaryDirectory.appendingPathComponent("home")
        let support = temporaryDirectory.appendingPathComponent("support")
        let backupStore = BackupStore(directory: support)
        let savedStore = SavedRelayStore(directory: support)
        let tester = ConnectivityTester { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data("{}".utf8), response)
        }
        let adapters: [ClientKind: any ConfigurationAdapter] = [
            .claude: ClaudeConfigurationAdapter(homeDirectory: home),
            .codex: CodexConfigurationAdapter(homeDirectory: home)
        ]
        let viewModel = RelaySetupModel(
            backupStore: backupStore,
            tester: tester,
            savedRelayStore: savedStore,
            adapters: adapters
        )
        viewModel.select(.codex)
        viewModel.profileName = "工作平台"
        viewModel.baseURL = "https://relay.example/v1"
        viewModel.apiKey = "test-key"
        viewModel.model = "gpt-b"
        viewModel.enabledModels = ["gpt-a", "gpt-b"]

        await viewModel.apply()

        let saved = try XCTUnwrap(savedStore.load().first)
        XCTAssertEqual(saved.name, "工作平台")
        XCTAssertEqual(saved.apiKey, "test-key")
        XCTAssertEqual(saved.clients[.codex]?.model, "gpt-b")
        XCTAssertEqual(Set(saved.clients[.codex]?.enabledModels ?? []), ["gpt-a", "gpt-b"])

        let reloaded = RelaySetupModel(
            backupStore: backupStore,
            tester: tester,
            savedRelayStore: savedStore,
            adapters: adapters
        )
        reloaded.select(.claude)
        reloaded.selectSavedProfile(saved.id)
        XCTAssertEqual(reloaded.profileName, "工作平台")
        XCTAssertEqual(reloaded.baseURL, "https://relay.example/v1")
        XCTAssertEqual(reloaded.apiKey, "test-key")
        XCTAssertEqual(reloaded.model, "")
        reloaded.select(.codex)
        reloaded.selectSavedProfile(saved.id)
        XCTAssertEqual(reloaded.model, "gpt-b")
        XCTAssertEqual(reloaded.enabledModels, ["gpt-a", "gpt-b"])
    }

    @MainActor
    func testDeletingSavedProfileDoesNotChangeClientConfiguration() throws {
        let home = temporaryDirectory.appendingPathComponent("home")
        let support = temporaryDirectory.appendingPathComponent("support")
        let codex = CodexConfigurationAdapter(homeDirectory: home)
        try codex.apply(RelayConfiguration(
            baseURL: "https://active.example/v1",
            model: "gpt-active",
            apiKey: "active-key",
            enabledModels: ["gpt-active"]
        ))
        let savedStore = SavedRelayStore(directory: support)
        let profile = SavedRelayProfile(
            id: UUID(),
            name: "可删除平台",
            baseURL: "https://saved.example/v1",
            apiKey: "saved-key",
            clients: [:],
            updatedAt: Date()
        )
        try savedStore.save([profile])
        let viewModel = RelaySetupModel(
            backupStore: BackupStore(directory: support),
            savedRelayStore: savedStore,
            adapters: [
                .claude: ClaudeConfigurationAdapter(homeDirectory: home),
                .codex: codex
            ]
        )
        viewModel.select(.codex)
        viewModel.selectSavedProfile(profile.id)

        viewModel.deleteSelectedProfile()

        XCTAssertTrue(try savedStore.load().isEmpty)
        XCTAssertEqual(try codex.currentConfiguration()?.baseURL, "https://active.example/v1")
    }

}

/// 记录探测请求的顺序，用来断言重试与端点探测。
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    @discardableResult
    func record(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request.url?.path ?? "")
        return recorded.count
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
