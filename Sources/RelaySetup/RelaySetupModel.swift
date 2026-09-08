import Foundation

@MainActor
final class RelaySetupModel: ObservableObject {
    @Published var selectedClient: ClientKind = .claude
    @Published var baseURL = ""
    @Published var model = ""
    @Published var apiKey = ""
    @Published var modelOptions: [String] = []
    @Published var enabledModels: Set<String> = []
    @Published private(set) var oneMillionContextModels: Set<String> = []
    @Published private(set) var legacyProviders: [LegacyProvider] = []
    @Published var redirectedProviders: Set<String> = []
    @Published private(set) var savedProfiles: [SavedRelayProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var profileName = ""
    @Published var statuses: [ClientKind: ConfigurationStatus] = [:]
    @Published var restorableClients: Set<ClientKind> = []
    @Published var isWorking = false
    @Published var isLoadingModels = false
    @Published var message: FeedbackMessage?
    @Published var showForceRestoreAlert = false

    private let backupStore: BackupStore
    private let tester: ConnectivityTester
    private let adapters: [ClientKind: any ConfigurationAdapter]
    private let savedRelayStore: SavedRelayStore

    struct FeedbackMessage: Equatable {
        enum Kind { case success, error }
        let kind: Kind
        let text: String
    }

    init(
        backupStore: BackupStore = BackupStore(),
        tester: ConnectivityTester = ConnectivityTester(),
        savedRelayStore: SavedRelayStore? = nil,
        adapters: [ClientKind: any ConfigurationAdapter]? = nil
    ) {
        self.backupStore = backupStore
        self.tester = tester
        self.savedRelayStore = savedRelayStore ?? SavedRelayStore(directory: backupStore.directory)
        self.adapters = adapters ?? [
            .claude: ClaudeConfigurationAdapter(),
            .codex: CodexConfigurationAdapter()
        ]
        loadSavedProfiles()
        refresh()
        loadCurrentConfiguration()
    }

    var selectedStatus: ConfigurationStatus {
        statuses[selectedClient] ?? .notConfigured
    }

    var canRestoreSelectedClient: Bool {
        restorableClients.contains(selectedClient)
    }

    var canApply: Bool {
        let defaultModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidModel = !defaultModel.isEmpty && enabledModels.contains(defaultModel)
        return !isWorking && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasValidModel
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func select(_ client: ClientKind) {
        selectedClient = client
        message = nil
        modelOptions = []
        enabledModels = []
        oneMillionContextModels = []
        refresh(client)
        loadCurrentConfiguration()
    }

    func loadModels() async {
        isLoadingModels = true
        message = nil
        do {
            let catalog = try await tester.fetchModels(baseURL: baseURL, apiKey: apiKey)
            modelOptions = catalog.models
            oneMillionContextModels = catalog.oneMillionContextModels
            message = FeedbackMessage(kind: .success, text: "已读取 \(modelOptions.count) 个模型。")
        } catch {
            modelOptions = []
            oneMillionContextModels = []
            message = FeedbackMessage(kind: .error, text: readable(error))
        }
        isLoadingModels = false
    }

    func apply() async {
        guard let adapter = adapters[selectedClient] else { return }
        let orderedEnabledModels = [model] + enabledModels.sorted().filter { $0 != model }
        let configuration = RelayConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            enabledModels: orderedEnabledModels,
            oneMillionContextModels: selectedClient == .claude
                ? oneMillionContextModels.intersection(enabledModels)
                : [],
            codexRedirectedProviders: redirectedProviders
                .filter { name in legacyProviders.contains { $0.name == name } }
                .sorted()
        ).trimmed
        isWorking = true
        message = nil

        do {
            try await tester.validate(configuration, for: selectedClient)
            try backupStore.ensureBaseline(for: selectedClient, paths: adapter.managedPaths)
            let beforeApply = try adapter.managedPaths.map(PrivateFileSystem.snapshot)
            do {
                try adapter.apply(configuration)
                try backupStore.markApplied(for: selectedClient, paths: adapter.managedPaths)
            } catch {
                for snapshot in beforeApply.reversed() {
                    try? PrivateFileSystem.restore(snapshot)
                }
                throw error
            }
            baseURL = configuration.baseURL
            model = configuration.model
            apiKey = configuration.apiKey
            enabledModels = Set(configuration.enabledModels)
            oneMillionContextModels = configuration.oneMillionContextModels
            let profileWarning = saveCurrentProfile(configuration)
            refresh()
            let redirected = configuration.codexRedirectedProviders
            let redirectNote = redirected.isEmpty
                ? ""
                : "旧对话使用的 \(redirected.joined(separator: "、")) 也已指向这个中转站。"
            message = FeedbackMessage(
                kind: .success,
                text: "配置已应用。\(redirectNote)\(selectedClient.restartInstruction)\(profileWarning ?? "")"
            )
        } catch {
            message = FeedbackMessage(kind: .error, text: readable(error))
        }
        isWorking = false
    }

    func requestRestore() {
        if selectedStatus == .changed {
            showForceRestoreAlert = true
        } else {
            restore(force: false)
        }
    }

    func restore(force: Bool) {
        isWorking = true
        message = nil
        do {
            try backupStore.restore(client: selectedClient, force: force)
            refresh()
            loadCurrentConfiguration()
            message = FeedbackMessage(kind: .success, text: "已还原 \(selectedClient.name) 的原始配置。")
        } catch {
            message = FeedbackMessage(kind: .error, text: readable(error))
        }
        isWorking = false
    }

    func refresh() {
        for client in ClientKind.allCases {
            refresh(client)
        }
    }

    private func refresh(_ client: ClientKind) {
        guard let adapter = adapters[client] else { return }
        do {
            let backupStatus = try backupStore.status(for: client)
            if backupStatus != .notConfigured {
                statuses[client] = backupStatus
                restorableClients.insert(client)
            } else {
                restorableClients.remove(client)
                statuses[client] = try adapter.currentConfiguration() == nil ? .notConfigured : .external
            }
        } catch {
            statuses[client] = .invalid
            restorableClients.remove(client)
        }
    }

    private func loadCurrentConfiguration() {
        guard let adapter = adapters[selectedClient] else { return }
        legacyProviders = adapter.legacyProviders()
        let configuration = try? adapter.currentConfiguration()
        if let configuration {
            baseURL = configuration.baseURL
            model = configuration.model
            apiKey = configuration.apiKey
            enabledModels = Set(configuration.enabledModels.isEmpty && !configuration.model.isEmpty
                ? [configuration.model]
                : configuration.enabledModels)
            oneMillionContextModels = configuration.oneMillionContextModels
        } else {
            baseURL = ""
            model = ""
            apiKey = ""
            enabledModels = []
            oneMillionContextModels = []
        }
        redirectedProviders = defaultRedirectedProviders(current: configuration)
        selectMatchingSavedProfile(for: configuration)
    }

    func selectSavedProfile(_ id: UUID?) {
        selectedProfileID = id
        message = nil
        guard let id, let profile = savedProfiles.first(where: { $0.id == id }) else {
            profileName = ""
            baseURL = ""
            apiKey = ""
            model = ""
            modelOptions = []
            enabledModels = []
            oneMillionContextModels = []
            return
        }
        profileName = profile.name
        baseURL = profile.baseURL
        apiKey = profile.apiKey
        let saved = profile.clients[selectedClient]
        model = saved?.model ?? ""
        enabledModels = Set(saved?.enabledModels ?? [])
        oneMillionContextModels = saved?.oneMillionContextModels ?? []
        modelOptions = saved?.enabledModels.sorted() ?? []
    }

    func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        let previous = savedProfiles
        savedProfiles.removeAll { $0.id == id }
        do {
            try savedRelayStore.save(savedProfiles)
            selectSavedProfile(nil)
        } catch {
            savedProfiles = previous
            message = FeedbackMessage(kind: .error, text: readable(error))
        }
    }

    private func loadSavedProfiles() {
        do {
            savedProfiles = try savedRelayStore.load()
        } catch {
            savedProfiles = []
            message = FeedbackMessage(kind: .error, text: readable(error))
        }
    }

    private func selectMatchingSavedProfile(for configuration: RelayConfiguration?) {
        guard let configuration,
              let profile = savedProfiles.first(where: {
                  $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                      .caseInsensitiveCompare(configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame
              }) else {
            selectedProfileID = nil
            profileName = ""
            return
        }
        selectedProfileID = profile.id
        profileName = profile.name
    }

    private func saveCurrentProfile(_ configuration: RelayConfiguration) -> String? {
        let now = Date()
        let requestedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = URL(string: configuration.baseURL)?.host ?? "中转站"
        let name = requestedName.isEmpty ? fallbackName : requestedName
        let clientConfiguration = SavedClientConfiguration(
            model: configuration.model,
            enabledModels: configuration.enabledModels,
            oneMillionContextModels: configuration.oneMillionContextModels
        )
        let matchingIndex = selectedProfileID.flatMap { id in
            savedProfiles.firstIndex { $0.id == id }
        } ?? savedProfiles.firstIndex {
            $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .caseInsensitiveCompare(configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame
        }

        if let index = matchingIndex {
            savedProfiles[index].name = name
            savedProfiles[index].baseURL = configuration.baseURL
            savedProfiles[index].apiKey = configuration.apiKey
            savedProfiles[index].clients[selectedClient] = clientConfiguration
            savedProfiles[index].updatedAt = now
            selectedProfileID = savedProfiles[index].id
        } else {
            let profile = SavedRelayProfile(
                id: UUID(),
                name: name,
                baseURL: configuration.baseURL,
                apiKey: configuration.apiKey,
                clients: [selectedClient: clientConfiguration],
                updatedAt: now
            )
            savedProfiles.append(profile)
            selectedProfileID = profile.id
        }
        profileName = name
        savedProfiles.sort { $0.updatedAt > $1.updatedAt }
        do {
            try savedRelayStore.save(savedProfiles)
            return nil
        } catch {
            return " 平台信息未能保存：\(readable(error))"
        }
    }

    /// 已经指向同一中转站的 provider 保持勾选；其余默认勾上那些确实有历史会话的，
    /// 否则换了中转站以后那些会话仍然会打旧地址。
    private func defaultRedirectedProviders(current: RelayConfiguration?) -> Set<String> {
        let names = Set(legacyProviders.map(\.name))
        if let current, !current.codexRedirectedProviders.isEmpty {
            return names.intersection(current.codexRedirectedProviders)
        }
        return Set(legacyProviders.filter { $0.sessionCount > 0 }.map(\.name))
    }

    func toggleEnabledModel(_ value: String) {
        if enabledModels.remove(value) != nil {
            if model == value {
                model = enabledModels.sorted().first ?? ""
            }
        } else {
            enabledModels.insert(value)
            if model.isEmpty { model = value }
        }
    }

    func enableAllModels(_ options: [String]) {
        enabledModels.formUnion(options)
        if model.isEmpty || !enabledModels.contains(model) {
            model = enabledModels.sorted().first ?? ""
        }
    }

    func clearEnabledModels() {
        enabledModels.removeAll()
        model = ""
    }

    func addManualModel(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !modelOptions.contains(value) {
            modelOptions.append(value)
            modelOptions.sort()
        }
        enabledModels.insert(value)
        model = value
    }

    private func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
