import Foundation

enum ClientKind: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    var protocolName: String {
        switch self {
        case .claude: "Anthropic Messages"
        case .codex: "OpenAI Responses"
        }
    }

    var restartInstruction: String {
        switch self {
        case .claude: "完全退出 Claude 桌面应用和 Claude Code 后重新打开即可生效。"
        case .codex: "重新打开 Codex 后即可生效。"
        }
    }
}

struct RelayConfiguration: Equatable {
    var baseURL: String
    var model: String
    var apiKey: String
    var enabledModels: [String] = []
    var oneMillionContextModels: Set<String> = []
    /// Codex 专用：除 RelayMate 自己的 provider 外，还要指向这个中转站的既有 provider 名。
    /// 历史对话记着自己创建时的 provider 名字，重写这些配置段才能让它们跟着换地址。
    var codexRedirectedProviders: [String] = []

    var trimmed: RelayConfiguration {
        let defaultModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let normalizedModels = enabledModels.compactMap { value -> String? in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
        var seenProviders = Set<String>()
        let normalizedProviders = codexRedirectedProviders.compactMap { value -> String? in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value != CodexConfigurationAdapter.profileName,
                  seenProviders.insert(value).inserted
            else { return nil }
            return value
        }
        return RelayConfiguration(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: defaultModel,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            enabledModels: normalizedModels,
            oneMillionContextModels: oneMillionContextModels.intersection(normalizedModels),
            codexRedirectedProviders: normalizedProviders
        )
    }
}

/// `config.toml` 里已经存在的、非 RelayMate 所有的 provider。
struct LegacyProvider: Equatable, Identifiable {
    let name: String
    let baseURL: String
    /// 记着这个 provider 名字的历史会话数量；读不到会话目录时为 0。
    let sessionCount: Int

    var id: String { name }
}

struct DiscoveredRelay: Equatable {
    let name: String
    let configuration: RelayConfiguration
}

struct ModelCatalog: Equatable {
    var models: [String]
    var oneMillionContextModels: Set<String>
}

struct SavedClientConfiguration: Codable, Equatable {
    var model: String
    var enabledModels: [String]
    var oneMillionContextModels: Set<String>
}

struct SavedRelayProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var clients: [ClientKind: SavedClientConfiguration]
    var updatedAt: Date
}

enum ConfigurationStatus: Equatable {
    case notConfigured
    case external
    case configured
    case changed
    case invalid

    var label: String {
        switch self {
        case .notConfigured: "未检测到中转配置"
        case .external: "已配置（非本工具管理）"
        case .configured: "由 RelayMate 管理"
        case .changed: "配置后来被修改"
        case .invalid: "配置无法读取"
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured: "circle"
        case .external: "link.circle.fill"
        case .configured: "checkmark.circle.fill"
        case .changed: "exclamationmark.triangle.fill"
        case .invalid: "xmark.octagon.fill"
        }
    }
}

enum RelaySetupError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case missingModel
    case missingAPIKey
    case invalidConfiguration(String)
    case network(String)
    case incompatible(String)
    case file(String)
    case noBackup
    case restoreConflict

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入完整的中转站 URL。"
        case .insecureURL: "远程中转站必须使用 HTTPS。"
        case .missingModel: "请输入默认模型。"
        case .missingAPIKey: "请输入 API Key。"
        case .invalidConfiguration(let message): "现有配置无法安全修改：\(message)"
        case .network(let message): "无法连接中转站：\(message)"
        case .incompatible(let message): "中转站不兼容：\(message)"
        case .file(let message): "配置文件操作失败：\(message)"
        case .noBackup: "没有找到可还原的原始配置。"
        case .restoreConflict: "配置文件在应用后被其他程序修改。继续还原会覆盖这些变化。"
        }
    }
}
