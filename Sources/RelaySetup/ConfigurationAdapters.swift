import Foundation

protocol ConfigurationAdapter {
    var client: ClientKind { get }
    var managedPaths: [URL] { get }
    func currentConfiguration() throws -> RelayConfiguration?
    func apply(_ configuration: RelayConfiguration) throws
    /// 客户端把历史会话绑在了 provider 名字上时，列出这些名字供用户一并接管。
    func legacyProviders() -> [LegacyProvider]
}

extension ConfigurationAdapter {
    /// Claude 没有按会话绑定的 provider：桌面端的网关 profile 是全局单选，
    /// Claude Code 从 settings.json 的 env 读取，重开即生效。
    func legacyProviders() -> [LegacyProvider] { [] }
}

struct ClaudeConfigurationAdapter: ConfigurationAdapter {
    static let desktopProfileID = "9b0875b6-24d4-4c87-9b3e-5df2b9a50d61"
    static let legacyDesktopProfileID = "9B0875B6-24D4-4C87-9B3E-5DF2B9A50D61"

    let client = ClientKind.claude
    let settingsURL: URL
    let desktopNormalConfigURL: URL
    let desktopThirdPartyConfigURL: URL
    let desktopProfileURL: URL
    let legacyDesktopProfileURL: URL
    let desktopMetaURL: URL
    let fileSystemIsCaseSensitive: Bool

    var managedPaths: [URL] {
        let profilePaths: [URL]
        if fileSystemIsCaseSensitive {
            profilePaths = [desktopProfileURL, legacyDesktopProfileURL]
        } else {
            profilePaths = [exactFileExists(at: legacyDesktopProfileURL) ? legacyDesktopProfileURL : desktopProfileURL]
        }
        return [
            settingsURL,
            desktopNormalConfigURL,
            desktopThirdPartyConfigURL
        ] + profilePaths + [desktopMetaURL]
    }

    init(homeDirectory: URL? = nil) {
        let homeDirectory = homeDirectory ?? Self.defaultHomeDirectory()
        fileSystemIsCaseSensitive = (
            try? homeDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames
        ) ?? false
        settingsURL = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        desktopNormalConfigURL = applicationSupport
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json")
        let thirdPartyDirectory = applicationSupport
            .appendingPathComponent("Claude-3p", isDirectory: true)
        desktopThirdPartyConfigURL = thirdPartyDirectory
            .appendingPathComponent("claude_desktop_config.json")
        let configLibrary = thirdPartyDirectory
            .appendingPathComponent("configLibrary", isDirectory: true)
        desktopProfileURL = configLibrary
            .appendingPathComponent("\(Self.desktopProfileID).json")
        legacyDesktopProfileURL = configLibrary
            .appendingPathComponent("\(Self.legacyDesktopProfileID).json")
        desktopMetaURL = configLibrary.appendingPathComponent("_meta.json")
    }

    private static func defaultHomeDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["RELAY_SETUP_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func currentConfiguration() throws -> RelayConfiguration? {
        let desktopConfiguration = try readDesktopConfiguration()
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let object = try readObject(at: settingsURL, context: "Claude Code settings.json")
            if let environment = object["env"] as? [String: Any],
               let baseURL = environment["ANTHROPIC_BASE_URL"] as? String,
               let model = environment["ANTHROPIC_MODEL"] as? String {
                let key = environment["ANTHROPIC_AUTH_TOKEN"] as? String
                    ?? environment["ANTHROPIC_API_KEY"] as? String
                    ?? ""
                return RelayConfiguration(
                    baseURL: baseURL,
                    model: model,
                    apiKey: key,
                    enabledModels: desktopConfiguration?.enabledModels ?? [model],
                    oneMillionContextModels: desktopConfiguration?.oneMillionContextModels ?? []
                )
            }
        }

        if let desktopConfiguration { return desktopConfiguration }
        if try desktopUsesThirdPartyDeployment() {
            return RelayConfiguration(baseURL: "", model: "", apiKey: "")
        }
        return nil
    }

    private func readDesktopConfiguration() throws -> RelayConfiguration? {
        let existingProfileURL = [desktopProfileURL, legacyDesktopProfileURL].first(where: exactFileExists)
        if let existingProfileURL {
            let profile = try readObject(at: existingProfileURL, context: "Claude 桌面网关配置")
            if let baseURL = profile["inferenceGatewayBaseUrl"] as? String,
               let key = profile["inferenceGatewayApiKey"] as? String,
               let models = profile["inferenceModels"] as? [Any] {
                let parsedModels = models.compactMap { item -> (name: String, supports1M: Bool)? in
                    if let name = item as? String { return (name, false) }
                    guard let object = item as? [String: Any],
                          let name = object["name"] as? String ?? object["id"] as? String
                    else { return nil }
                    return (name, object["supports1m"] as? Bool == true)
                }
                guard let model = parsedModels.first?.name else { return nil }
                return RelayConfiguration(
                    baseURL: baseURL,
                    model: model,
                    apiKey: key,
                    enabledModels: parsedModels.map(\.name),
                    oneMillionContextModels: Set(
                        parsedModels.filter(\.supports1M).map(\.name)
                    )
                )
            }
        }
        return nil
    }

    func apply(_ configuration: RelayConfiguration) throws {
        let enabledModels = configuration.enabledModels.isEmpty
            ? [configuration.model]
            : configuration.enabledModels
        guard enabledModels.contains(configuration.model) else {
            throw RelaySetupError.incompatible("默认模型必须包含在已启用模型中。")
        }
        guard enabledModels.allSatisfy(Self.isClaudeDesktopModelID) else {
            throw RelaySetupError.incompatible(
                "Claude 桌面应用只接受 claude-sonnet-*、claude-opus-*、claude-haiku-* 或 claude-fable-* 模型名。"
            )
        }

        var object = try readObject(at: settingsURL, context: "Claude Code settings.json")
        var environment = object["env"] as? [String: Any] ?? [:]
        environment["ANTHROPIC_BASE_URL"] = Self.runtimeBaseURL(configuration.baseURL)
        environment["ANTHROPIC_AUTH_TOKEN"] = configuration.apiKey
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment["ANTHROPIC_MODEL"] = configuration.model
        object["env"] = environment

        try writeObject(object, to: settingsURL)
        try writeDeploymentMode("3p", to: desktopNormalConfigURL)
        try writeDeploymentMode("3p", to: desktopThirdPartyConfigURL)
        try removeLegacyDesktopProfile()
        try writeDesktopProfile(configuration, enabledModels: enabledModels)
        try selectDesktopProfile()
    }

    static func runtimeBaseURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") {
            path.removeLast(3)
        }
        components.path = path
        return components.string ?? value
    }

    static func isClaudeDesktopModelID(_ value: String) -> Bool {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let route: Substring
        if model.hasPrefix("anthropic/claude-") {
            route = model.dropFirst("anthropic/claude-".count)
        } else if model.hasPrefix("claude-") {
            route = model.dropFirst("claude-".count)
        } else {
            return false
        }
        return ["sonnet-", "opus-", "haiku-", "fable-"].contains { route.hasPrefix($0) }
    }

    private func desktopUsesThirdPartyDeployment() throws -> Bool {
        for url in [desktopNormalConfigURL, desktopThirdPartyConfigURL] where FileManager.default.fileExists(atPath: url.path) {
            let object = try readObject(at: url, context: "Claude 桌面配置")
            if object["deploymentMode"] as? String == "3p" { return true }
        }
        if FileManager.default.fileExists(atPath: desktopMetaURL.path) {
            let meta = try readObject(at: desktopMetaURL, context: "Claude 桌面配置索引")
            if meta["appliedId"] as? String != nil { return true }
        }
        return false
    }

    private func writeDeploymentMode(_ mode: String, to url: URL) throws {
        var object = try readObject(at: url, context: "Claude 桌面配置")
        object["deploymentMode"] = mode
        try writeObject(object, to: url)
    }

    private func writeDesktopProfile(_ configuration: RelayConfiguration, enabledModels: [String]) throws {
        let orderedModels = [configuration.model] + enabledModels.filter { $0 != configuration.model }
        let profileModels: [Any] = orderedModels.map { model in
            guard configuration.oneMillionContextModels.contains(model) else { return model }
            return ["name": model, "supports1m": true] as [String: Any]
        }
        let profile: [String: Any] = [
            "coworkEgressAllowedHosts": ["*"],
            "disableDeploymentModeChooser": true,
            "inferenceGatewayApiKey": configuration.apiKey,
            "inferenceGatewayAuthScheme": "bearer",
            "inferenceGatewayBaseUrl": Self.runtimeBaseURL(configuration.baseURL),
            "inferenceModels": profileModels,
            "inferenceProvider": "gateway"
        ]
        try writeObject(profile, to: desktopProfileURL)
    }

    private func selectDesktopProfile() throws {
        var meta = try readObject(at: desktopMetaURL, context: "Claude 桌面配置索引")
        var entries = meta["entries"] as? [[String: Any]] ?? []
        entries.removeAll {
            guard let id = $0["id"] as? String else { return false }
            return id.caseInsensitiveCompare(Self.desktopProfileID) == .orderedSame
        }
        entries.append(["id": Self.desktopProfileID, "name": "RelayMate"])
        meta["entries"] = entries
        meta["appliedId"] = Self.desktopProfileID
        try writeObject(meta, to: desktopMetaURL)
    }

    private func removeLegacyDesktopProfile() throws {
        guard exactFileExists(at: legacyDesktopProfileURL) else { return }
        do {
            try FileManager.default.removeItem(at: legacyDesktopProfileURL)
        } catch {
            throw RelaySetupError.file(error.localizedDescription)
        }
    }

    private func exactFileExists(at url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains(url.lastPathComponent)
    }

    private func readObject(at url: URL, context: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let object = value as? [String: Any] else {
                throw RelaySetupError.invalidConfiguration("\(context) 顶层必须是对象。")
            }
            if url == settingsURL, let environment = object["env"], !(environment is [String: Any]) {
                throw RelaySetupError.invalidConfiguration("Claude Code 的 env 字段必须是对象。")
            }
            return object
        } catch let error as RelaySetupError {
            throw error
        } catch {
            throw RelaySetupError.invalidConfiguration(error.localizedDescription)
        }
    }

    private func writeObject(_ object: [String: Any], to url: URL) throws {
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            try PrivateFileSystem.write(data, to: url)
        } catch let error as RelaySetupError {
            throw error
        } catch {
            throw RelaySetupError.invalidConfiguration(error.localizedDescription)
        }
    }
}

struct CodexConfigurationAdapter: ConfigurationAdapter {
    static let profileName = "relay-setup"
    static let catalogFileName = "relaymate-model-catalog.json"

    let client = ClientKind.codex
    let configURL: URL
    let profileURL: URL
    let catalogURL: URL
    let modelCacheURL: URL
    let sessionsURL: URL

    var managedPaths: [URL] { [configURL, profileURL, catalogURL] }

    init(homeDirectory: URL? = nil) {
        let homeDirectory = homeDirectory ?? Self.defaultHomeDirectory()
        let environment = ProcessInfo.processInfo.environment
        let codexDirectory: URL
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            codexDirectory = URL(fileURLWithPath: override)
        } else {
            codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        configURL = codexDirectory.appendingPathComponent("config.toml")
        profileURL = codexDirectory.appendingPathComponent("\(Self.profileName).config.toml")
        catalogURL = codexDirectory.appendingPathComponent(Self.catalogFileName)
        modelCacheURL = codexDirectory.appendingPathComponent("models_cache.json")
        sessionsURL = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    private static func defaultHomeDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["RELAY_SETUP_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func currentConfiguration() throws -> RelayConfiguration? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let text: String
        do {
            text = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            throw RelaySetupError.invalidConfiguration(error.localizedDescription)
        }

        guard let model = TOMLText.topLevelValue(for: "model", in: text) else { return nil }
        let enabledModels = try readOwnedCatalog(from: text) ?? [model]
        let provider = TOMLText.topLevelValue(for: "model_provider", in: text) ?? "openai"
        if provider == "openai",
           let baseURL = TOMLText.topLevelValue(for: "openai_base_url", in: text) {
            return RelayConfiguration(
                baseURL: baseURL,
                model: model,
                apiKey: "",
                enabledModels: enabledModels
            )
        }
        guard let providerText = TOMLText.table(named: "model_providers.\(provider)", in: text),
              let baseURL = TOMLText.value(for: "base_url", in: providerText)
        else { return nil }
        let key = TOMLText.value(for: "experimental_bearer_token", in: providerText) ?? ""
        return RelayConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: key,
            enabledModels: enabledModels,
            codexRedirectedProviders: redirectedProviders(in: text, baseURL: baseURL, activeProvider: provider)
        )
    }

    /// 已经被指向同一个中转站的其他 provider —— 重开向导时据此还原勾选状态。
    private func redirectedProviders(in text: String, baseURL: String, activeProvider: String) -> [String] {
        providerNames(in: text)
            .filter { $0 != activeProvider && $0 != Self.profileName }
            .filter { name in
                guard let table = TOMLText.table(named: "model_providers.\(name)", in: text) else { return false }
                return TOMLText.value(for: "base_url", in: table) == baseURL
            }
    }

    private func providerNames(in text: String) -> [String] {
        TOMLText.tableNames(withPrefix: "model_providers", in: text)
    }

    func legacyProviders() -> [LegacyProvider] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        let names = providerNames(in: text).filter { $0 != Self.profileName }
        guard !names.isEmpty else { return [] }
        let usage = sessionProviderUsage()
        return names.map { name in
            let table = TOMLText.table(named: "model_providers.\(name)", in: text)
            return LegacyProvider(
                name: name,
                baseURL: table.flatMap { TOMLText.value(for: "base_url", in: $0) } ?? "",
                sessionCount: usage[name] ?? 0
            )
        }
    }

    /// 统计每个 provider 名字被多少个历史会话记住。会话记录的第一行是 `session_meta`，
    /// 里面带 `"model_provider":"…"`；这一行含 base instructions，本机实测约 22 KB，
    /// 所以每个文件只读 64 KiB 并按 JSON 解析首行 —— 会话目录本身可能有若干 GB、
    /// 单个文件几百 MB，而这个统计是在向导里同步跑的。读不到首行就跳过。
    private func sessionProviderUsage(limit: Int = 1000) -> [String: Int] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }

        var usage: [String: Int] = [:]
        var inspected = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if inspected >= limit { break }
            inspected += 1
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65_536),
                  let newline = data.firstIndex(of: 0x0A) ?? (data.count < 65_536 ? data.endIndex : nil),
                  case let firstLine = data[data.startIndex..<newline],
                  let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let provider = payload["model_provider"] as? String,
                  !provider.isEmpty
            else { continue }
            usage[provider, default: 0] += 1
        }
        return usage
    }

    func apply(_ configuration: RelayConfiguration) throws {
        let originalMain = try PrivateFileSystem.snapshot(configURL)
        let originalProfile = try PrivateFileSystem.snapshot(profileURL)
        let originalCatalog = try PrivateFileSystem.snapshot(catalogURL)
        let enabledModels = configuration.enabledModels.isEmpty
            ? [configuration.model]
            : configuration.enabledModels
        guard enabledModels.contains(configuration.model) else {
            throw RelaySetupError.incompatible("默认模型必须包含在已启用模型中。")
        }

        do {
            let mainText: String
            if originalMain.existed {
                guard let data = originalMain.contents,
                      let value = String(data: data, encoding: .utf8)
                else {
                    throw RelaySetupError.invalidConfiguration("Codex config.toml 不是 UTF-8 文本。")
                }
                mainText = value
            } else {
                mainText = ""
            }

            var updatedMain = try TOMLText.removingTopLevelString(
                key: "profile", value: Self.profileName, in: mainText
            )
            updatedMain = try TOMLText.settingTopLevelString(
                key: "model", value: configuration.model, in: updatedMain
            )
            updatedMain = try TOMLText.settingTopLevelString(
                key: "model_provider", value: Self.profileName, in: updatedMain
            )
            updatedMain = try TOMLText.settingTopLevelString(
                key: "model_catalog_json", value: Self.catalogFileName, in: updatedMain
            )
            updatedMain = try TOMLText.settingTable(
                named: "model_providers.\(Self.profileName)",
                body: provider(configuration),
                in: updatedMain
            )
            // 历史对话按 provider 名字寻址，把用户勾选的旧 provider 也指到这个中转站，
            // 整段替换（旧的 env_key、requires_openai_auth 之类会和新线路冲突），只留显示名。
            for name in configuration.codexRedirectedProviders where name != Self.profileName {
                let table = "model_providers.\(name)"
                let displayName = TOMLText.table(named: table, in: updatedMain)
                    .flatMap { TOMLText.value(for: "name", in: $0) } ?? name
                updatedMain = try TOMLText.settingTable(
                    named: table,
                    body: provider(configuration, displayName: displayName),
                    in: updatedMain
                )
            }
            try writeCatalog(defaultModel: configuration.model, enabledModels: enabledModels)
            try PrivateFileSystem.write(Data(updatedMain.utf8), to: configURL)
            if FileManager.default.fileExists(atPath: profileURL.path) {
                try FileManager.default.removeItem(at: profileURL)
            }
        } catch {
            try? PrivateFileSystem.restore(originalCatalog)
            try? PrivateFileSystem.restore(originalProfile)
            try? PrivateFileSystem.restore(originalMain)
            throw error
        }
    }

    private func readOwnedCatalog(from configText: String) throws -> [String]? {
        guard let pointer = TOMLText.topLevelValue(for: "model_catalog_json", in: configText),
              URL(fileURLWithPath: pointer).lastPathComponent == Self.catalogFileName
        else { return nil }
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw RelaySetupError.invalidConfiguration("RelayMate 的 Codex 模型目录不存在。")
        }
        do {
            let data = try Data(contentsOf: catalogURL)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = root?["models"] as? [[String: Any]] ?? []
            let identifiers = models.compactMap { $0["slug"] as? String }
            guard !identifiers.isEmpty else {
                throw RelaySetupError.invalidConfiguration("RelayMate 的 Codex 模型目录为空。")
            }
            return identifiers
        } catch let error as RelaySetupError {
            throw error
        } catch {
            throw RelaySetupError.invalidConfiguration("RelayMate 的 Codex 模型目录无法读取。")
        }
    }

    private func writeCatalog(defaultModel: String, enabledModels: [String]) throws {
        let orderedModels = [defaultModel] + enabledModels.filter { $0 != defaultModel }
        let cachedModels = cachedModelMetadata()
        let entries = orderedModels.enumerated().map { index, model -> [String: Any] in
            var entry = cachedModels[model] ?? Self.fallbackCatalogEntry(for: model)
            entry["slug"] = model
            entry["display_name"] = model
            entry["description"] = model
            entry["visibility"] = "list"
            entry["supported_in_api"] = true
            entry["priority"] = 1000 + index
            entry["additional_speed_tiers"] = []
            entry["service_tiers"] = []
            entry.removeValue(forKey: "default_service_tier")
            return entry
        }
        do {
            var data = try JSONSerialization.data(
                withJSONObject: ["models": entries],
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            try PrivateFileSystem.write(data, to: catalogURL)
        } catch let error as RelaySetupError {
            throw error
        } catch {
            throw RelaySetupError.invalidConfiguration("无法生成 Codex 模型目录。")
        }
    }

    private func cachedModelMetadata() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: modelCacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]]
        else { return [:] }
        return models.reduce(into: [:]) { result, entry in
            guard let slug = entry["slug"] as? String else { return }
            result[slug] = entry
        }
    }

    private static func fallbackCatalogEntry(for model: String) -> [String: Any] {
        [
            "slug": model,
            "display_name": model,
            "description": model,
            "base_instructions": "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals.",
            "default_reasoning_level": "high",
            "supported_reasoning_levels": [
                ["effort": "none", "description": "Disable Thinking"],
                ["effort": "high", "description": "Enabled Thinking"]
            ],
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": 0,
            "supports_reasoning_summaries": true,
            "default_reasoning_summary": "none",
            "support_verbosity": false,
            "truncation_policy": ["mode": "bytes", "limit": 10_000],
            "supports_parallel_tool_calls": false,
            "supports_image_detail_original": false,
            "context_window": 128_000,
            "max_context_window": 128_000,
            "effective_context_window_percent": 95,
            "experimental_supported_tools": [],
            "input_modalities": ["text", "image"],
            "supports_search_tool": false
        ]
    }

    private func provider(_ configuration: RelayConfiguration, displayName: String = "API Relay") -> String {
        """
        name = \(TOMLText.quoted(displayName))
        base_url = \(TOMLText.quoted(configuration.baseURL))
        wire_api = "responses"
        requires_openai_auth = false
        experimental_bearer_token = \(TOMLText.quoted(configuration.apiKey))

        """
    }
}

enum TOMLText {
    static func settingTopLevelString(key: String, value: String, in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let assignment = "\(key) = \(quoted(value))"
        var matches: [Int] = []
        var insideTable = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                insideTable = true
            }
            if !insideTable, isAssignment(line, key: key) {
                matches.append(index)
            }
        }

        guard matches.count <= 1 else {
            throw RelaySetupError.invalidConfiguration("Codex config.toml 包含重复的顶层 \(key) 字段。")
        }

        if let index = matches.first {
            lines[index] = assignment
        } else if let tableIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }) {
            lines.insert(assignment, at: tableIndex)
            lines.insert("", at: tableIndex + 1)
        } else {
            while lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append(assignment)
        }

        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    static func value(for key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") where isAssignment(line, key: key) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return unquote(String(raw))
        }
        return nil
    }

    static func topLevelValue(for key: String, in text: String) -> String? {
        var insideTable = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { insideTable = true }
            guard !insideTable, isAssignment(line, key: key),
                  let equals = line.firstIndex(of: "=") else { continue }
            let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return unquote(String(raw))
        }
        return nil
    }

    static func removingTopLevelString(key: String, value: String, in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        var matches: [Int] = []
        var insideTable = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { insideTable = true }
            if !insideTable, isAssignment(line, key: key) { matches.append(index) }
        }
        guard matches.count <= 1 else {
            throw RelaySetupError.invalidConfiguration("Codex config.toml 包含重复的顶层 \(key) 字段。")
        }
        if let index = matches.first,
           topLevelValue(for: key, in: text) == value {
            lines.remove(at: index)
        }
        while lines.last == "" { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func table(named name: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let header = "[\(name)]"
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == header
        }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }) ?? lines.endIndex
        return lines[(start + 1)..<end].joined(separator: "\n")
    }

    /// `[prefix.name]` 形式的子表名，按出现顺序返回。裸的 `[prefix]` 不算，
    /// 引号形式 `[prefix."with.dot"]` 会被原样保留（含引号），交由调用方按同样的字面量寻址。
    static func tableNames(withPrefix prefix: String, in text: String) -> [String] {
        var names: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[\(prefix)."), trimmed.hasSuffix("]") else { continue }
            let name = String(trimmed.dropFirst(prefix.count + 2).dropLast())
            // `[model_providers.custom.http_headers]` 是 provider 的子表，不是另一个 provider。
            let isNested = name.contains(".") && !name.hasPrefix("\"")
            guard !name.isEmpty, !isNested, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    static func settingTable(named name: String, body: String, in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        let header = "[\(name)]"
        let starts = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == header
        }
        guard starts.count <= 1 else {
            throw RelaySetupError.invalidConfiguration("Codex config.toml 包含重复的 \(header) 配置段。")
        }
        let replacement = [header] + body.components(separatedBy: "\n").filter { !$0.isEmpty }
        if let start = starts.first {
            let end = lines[(start + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            }) ?? lines.endIndex
            lines.replaceSubrange(start..<end, with: replacement + [""])
        } else {
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: replacement)
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func isAssignment(_ line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(key) else { return false }
        let remainder = trimmed.dropFirst(key.count)
        guard let first = remainder.first else { return false }
        return first == " " || first == "\t" || first == "="
    }

    private static func unquote(_ value: String) -> String? {
        guard value.first == "\"" else { return nil }
        var output = ""
        var escaped = false
        for character in value.dropFirst() {
            if escaped {
                switch character {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                default: output.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return output
            } else {
                output.append(character)
            }
        }
        return nil
    }
}
