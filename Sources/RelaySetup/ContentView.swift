import SwiftUI

struct ContentView: View {
    @StateObject private var model = RelaySetupModel()
    @State private var step: WizardStep = .client
    @State private var setupBackStep: WizardStep = .client
    @State private var modelSearch = ""
    @State private var manualModel = ""
    @State private var showDeleteProfileAlert = false
    @FocusState private var focusedField: Field?

    private enum WizardStep {
        case client
        case existing
        case url
        case key
        case model
        case result
    }

    private enum Field { case url, key, modelSearch, manualModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.vertical, 20)
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 520)
        .onSubmit(performSubmit)
        .onChange(of: step) { newStep in
            DispatchQueue.main.async {
                switch newStep {
                case .url: focusedField = .url
                case .key: focusedField = .key
                case .model: focusedField = .modelSearch
                default: focusedField = nil
                }
            }
        }
        .alert("配置已被修改", isPresented: $model.showForceRestoreAlert) {
            Button("取消", role: .cancel) {}
            Button("仍然还原", role: .destructive) {
                model.restore(force: true)
            }
        } message: {
            Text("还原会覆盖配置应用之后对相关文件所做的修改。")
        }
        .alert("删除保存的平台？", isPresented: $showDeleteProfileAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                model.deleteSelectedProfile()
            }
        } message: {
            Text("只会删除 RelayMate 保存的平台资料，不会修改当前的 Claude 或 Codex 配置。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("RelayMate")
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progressStep {
                VStack(alignment: .trailing, spacing: 5) {
                    Text("第 \(progressStep) 步，共 4 步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(progressStep), total: 4)
                        .frame(width: 108)
                        .accessibilityLabel("设置进度")
                        .accessibilityValue("第 \(progressStep) 步，共 4 步")
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .client: clientStep
        case .existing: existingStep
        case .url: urlStep
        case .key: keyStep
        case .model: modelStep
        case .result: resultStep
        }
    }

    private var clientStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading("选择 AI 工具", detail: "选择需要接入中转站的软件。")
            HStack(spacing: 14) {
                ForEach(ClientKind.allCases) { client in
                    Button {
                        choose(client)
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: client.symbol)
                                .font(.system(size: 27, weight: .medium))
                                .foregroundStyle(.tint)
                            Text(client.name)
                                .font(.headline)
                            Text(clientDescription(client))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            clientStatus(client)
                        }
                        .frame(maxWidth: .infinity, minHeight: 122)
                    }
                    .buttonStyle(ClientChoiceButtonStyle())
                    .accessibilityHint("选择后开始设置或管理现有配置")
                }
            }
            Spacer()
        }
    }

    private var existingStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading("\(model.selectedClient.name) 配置", detail: existingDetail)
            statusRow
            if model.selectedStatus == .external || model.selectedStatus == .configured || model.selectedStatus == .changed {
                VStack(alignment: .leading, spacing: 10) {
                    configurationRow("中转站", value: model.baseURL)
                    configurationRow("模型", value: model.model)
                }
                .padding(14)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            feedback
            Spacer()
            HStack {
                Button("返回") { step = .client }
                Spacer()
                if model.canRestoreSelectedClient {
                    Button("还原原配置", role: .destructive) {
                        model.requestRestore()
                    }
                    .disabled(model.isWorking)
                }
                Button(model.selectedStatus == .notConfigured ? "开始设置" : "重新设置") {
                    setupBackStep = .existing
                    model.message = nil
                    step = .url
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || model.selectedStatus == .invalid)
            }
        }
    }

    private var urlStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading("选择中转站", detail: "选择保存的平台，或填写一个新的中转站。")
            if !model.savedProfiles.isEmpty {
                field("已保存的平台") {
                    HStack(spacing: 8) {
                        Picker("已保存的平台", selection: savedProfileBinding) {
                            Text("新平台").tag(UUID?.none)
                            ForEach(model.savedProfiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            model.selectSavedProfile(nil)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("添加新平台")
                        Button(role: .destructive) {
                            showDeleteProfileAlert = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("删除所选平台")
                        .disabled(model.selectedProfileID == nil)
                    }
                }
            }
            field("平台名称") {
                TextField("例如：常用中转站", text: $model.profileName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("用于在 RelayMate 中区分多个中转站")
            }
            field("中转站 URL") {
                TextField("https://api.example.com/v1", text: $model.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .url)
                    .accessibilityHint("输入中转站提供的完整基础地址")
            }
            legacyProviderSection
            Spacer()
            navigation(back: setupBackStep, nextTitle: "下一步", nextDisabled: trimmed(model.baseURL).isEmpty) {
                model.message = nil
                step = .key
            }
        }
    }

    @ViewBuilder
    private var legacyProviderSection: some View {
        if !model.legacyProviders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("让旧对话也用这个中转站")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("Codex 的历史对话记着自己创建时的 provider 名字。勾选后这些对话也会指向这里，对应配置段会被覆盖，还原时可恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.legacyProviders) { provider in
                    Toggle(legacyProviderLabel(provider), isOn: redirectBinding(for: provider.name))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func legacyProviderLabel(_ provider: LegacyProvider) -> String {
        provider.sessionCount > 0
            ? "\(provider.name)（\(provider.sessionCount) 个历史对话）"
            : provider.name
    }

    private func redirectBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { model.redirectedProviders.contains(name) },
            set: { enabled in
                if enabled {
                    model.redirectedProviders.insert(name)
                } else {
                    model.redirectedProviders.remove(name)
                }
            }
        )
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading("输入 API Key", detail: "Key 仅写入所选工具的本机配置和私有备份。")
            field("API Key") {
                SecureField("输入 API Key", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .key)
            }
            Spacer()
            navigation(back: .url, nextTitle: "读取模型", nextDisabled: trimmed(model.apiKey).isEmpty) {
                openModelStep()
            }
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                stepHeading(modelStepTitle, detail: modelStepDetail)
                Spacer()
                if !availableModels.isEmpty {
                    Button("全选") { model.enableAllModels(availableModels) }
                        .disabled(allAvailableModelsEnabled)
                    Button("清除") { model.clearEnabledModels() }
                        .disabled(model.enabledModels.isEmpty)
                }
                Button {
                    Task { await model.loadModels() }
                } label: {
                    if model.isLoadingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("重新读取", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoadingModels)
            }
            if model.isLoadingModels && model.modelOptions.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取模型列表…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 138)
            } else if !model.modelOptions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索 \(availableModels.count) 个模型", text: $modelSearch)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .modelSearch)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                ScrollView {
                    ModelFlowLayout(horizontalSpacing: 18, verticalSpacing: 12) {
                        ForEach(filteredModels, id: \.self) { option in
                            Toggle(isOn: enabledBinding(for: option)) {
                                Text(option)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .toggleStyle(.checkbox)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityHint(
                                model.selectedClient == .claude
                                    ? "控制该模型是否出现在 Claude 的模型菜单中"
                                    : "控制该模型是否出现在 Codex 的模型菜单中"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(height: 126)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                field("默认模型") {
                    Picker("默认模型", selection: $model.model) {
                        ForEach(model.enabledModels.sorted(), id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.enabledModels.isEmpty)
                }
                field("手动添加") {
                    HStack(spacing: 6) {
                        TextField("模型名", text: $manualModel)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .manualModel)
                        Button {
                            addManualModel()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("添加并设为默认模型")
                        .disabled(trimmed(manualModel).isEmpty)
                    }
                }
                .frame(width: 230)
            }
            feedback
            Spacer(minLength: 8)
            HStack {
                Button("上一步") { step = .key }
                Spacer()
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在测试并应用配置")
                }
                Button("测试并应用") {
                    testAndApply()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApply || model.isLoadingModels)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var resultStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                stepHeading("配置完成", detail: model.selectedClient.restartInstruction)
            }
            VStack(alignment: .leading, spacing: 10) {
                configurationRow("AI 工具", value: model.selectedClient.name)
                configurationRow("保存名称", value: model.profileName)
                configurationRow("中转站", value: model.baseURL)
                configurationRow("默认模型", value: model.model)
                configurationRow("启用模型", value: "\(model.enabledModels.count) 个")
            }
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            Spacer()
            HStack {
                Button("修改当前配置") {
                    setupBackStep = .existing
                    model.message = nil
                    step = .url
                }
                Spacer()
                Button("设置另一个工具") {
                    model.message = nil
                    step = .client
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func stepHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.callout.weight(.medium))
            content()
        }
    }

    private func configurationRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value.isEmpty ? "未读取" : value)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func clientStatus(_ client: ClientKind) -> some View {
        let status = model.statuses[client] ?? .notConfigured
        return Label(status.label, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(color(for: status))
    }

    private var statusRow: some View {
        HStack(spacing: 9) {
            Image(systemName: model.selectedStatus.symbol)
                .foregroundStyle(color(for: model.selectedStatus))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedStatus.label)
                    .font(.headline)
                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.selectedClient.protocolName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var feedback: some View {
        if let feedback = model.message {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: feedback.kind == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                Text(feedback.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            .font(.callout)
            .foregroundStyle(feedback.kind == .success ? Color.green : Color.red)
            .accessibilityElement(children: .combine)
        }
    }

    private func navigation(
        back: WizardStep,
        nextTitle: String,
        nextDisabled: Bool,
        next: @escaping () -> Void
    ) -> some View {
        HStack {
            Button("上一步") { step = back }
            Spacer()
            Button(nextTitle, action: next)
                .buttonStyle(.borderedProminent)
                .disabled(nextDisabled)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var filteredModels: [String] {
        let query = trimmed(modelSearch)
        guard !query.isEmpty else { return availableModels }
        return availableModels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var savedProfileBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedProfileID },
            set: { model.selectSavedProfile($0) }
        )
    }

    private var availableModels: [String] {
        guard model.selectedClient == .claude else { return model.modelOptions }
        return model.modelOptions.filter(ClaudeConfigurationAdapter.isClaudeDesktopModelID)
    }

    private var allAvailableModelsEnabled: Bool {
        !availableModels.isEmpty && availableModels.allSatisfy(model.enabledModels.contains)
    }

    private var modelStepTitle: String {
        "选择启用模型"
    }

    private var modelStepDetail: String {
        model.selectedClient == .claude
            ? "勾选要显示在 Claude 中的模型，再指定一个默认模型。"
            : "勾选要显示在 Codex 中的模型，再指定一个默认模型。"
    }

    private func enabledBinding(for option: String) -> Binding<Bool> {
        Binding(
            get: { model.enabledModels.contains(option) },
            set: { enabled in
                if enabled != model.enabledModels.contains(option) {
                    model.toggleEnabledModel(option)
                }
            }
        )
    }

    private var headerSubtitle: String {
        switch step {
        case .client: "配置 API 中转站"
        case .existing: "管理现有配置"
        case .url, .key, .model: model.selectedClient.name
        case .result: "已完成"
        }
    }

    private var progressStep: Int? {
        switch step {
        case .client: 1
        case .url: 2
        case .key: 3
        case .model: 4
        case .existing, .result: nil
        }
    }

    private var existingDetail: String {
        switch model.selectedStatus {
        case .notConfigured:
            "没有发现中转配置，可以开始设置。"
        case .external:
            "这是从目标软件自己的配置文件中检测到的设置。本工具尚未修改它，可以继续向导更新。"
        case .configured:
            "可以还原首次设置前的文件，或继续向导更新信息。"
        case .changed:
            "配置应用后又发生了变化，可以重新设置；还原时需要确认。"
        case .invalid:
            "目标软件的配置文件无法安全读取，请先修复格式后再设置。"
        }
    }

    private var statusDescription: String {
        switch model.selectedStatus {
        case .notConfigured: "扫描完成，当前使用官方服务或尚未配置。"
        case .external: "扫描完成，当前设置不由 RelayMate 管理，因此不能直接还原。"
        case .configured: "扫描完成，配置文件与上次应用的内容一致。"
        case .changed: "扫描完成，配置文件后来发生了变化。"
        case .invalid: "扫描完成，但配置文件格式不正确或不可读取。"
        }
    }

    private func color(for status: ConfigurationStatus) -> Color {
        switch status {
        case .notConfigured: .secondary
        case .external: .blue
        case .configured: .green
        case .changed: .orange
        case .invalid: .red
        }
    }

    private func clientDescription(_ client: ClientKind) -> String {
        switch client {
        case .claude: "Claude 桌面应用与 Claude Code"
        case .codex: "OpenAI Codex"
        }
    }

    private func choose(_ client: ClientKind) {
        model.select(client)
        modelSearch = ""
        setupBackStep = .client
        step = model.selectedStatus == .notConfigured ? .url : .existing
    }

    private func openModelStep() {
        model.message = nil
        model.modelOptions = []
        modelSearch = ""
        manualModel = ""
        step = .model
        Task { await model.loadModels() }
    }

    private func addManualModel() {
        model.addManualModel(manualModel)
        manualModel = ""
    }

    private func testAndApply() {
        Task {
            await model.apply()
            if model.selectedStatus == .configured,
               model.message?.kind == .success {
                step = .result
            }
        }
    }

    private func performSubmit() {
        switch step {
        case .url where !trimmed(model.baseURL).isEmpty:
            step = .key
        case .key where !trimmed(model.apiKey).isEmpty:
            openModelStep()
        case .model:
            if focusedField == .manualModel && !trimmed(manualModel).isEmpty {
                addManualModel()
            } else if model.canApply && !model.isLoadingModels {
                testAndApply()
            }
        default:
            break
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ModelFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var position = CGPoint.zero
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let spacing = position.x == 0 ? 0 : horizontalSpacing
            if position.x > 0, position.x + spacing + size.width > maximumWidth {
                position.x = 0
                position.y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            let itemSpacing = position.x == 0 ? 0 : horizontalSpacing
            position.x += itemSpacing + size.width
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, position.x)
        }

        return CGSize(width: min(usedWidth, maximumWidth), height: position.y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let spacing = x == bounds.minX ? 0 : horizontalSpacing
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if x > bounds.minX { x += horizontalSpacing }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ClientChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        configuration.isPressed ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.22),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
