import Foundation

struct ConnectivityTester {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let sender: Sender

    init(session: URLSession = .shared) {
        sender = { request in
            try await session.data(for: request)
        }
    }

    init(sender: @escaping Sender) {
        self.sender = sender
    }

    func validate(_ configuration: RelayConfiguration, for client: ClientKind) async throws {
        let configuration = configuration.trimmed
        let baseURL = try validatedBaseURL(configuration.baseURL)
        guard !configuration.model.isEmpty else { throw RelaySetupError.missingModel }
        guard !configuration.apiKey.isEmpty else { throw RelaySetupError.missingAPIKey }

        do {
            try await probe(configuration, baseURL: baseURL, client: client, endpoint: .responses)
        } catch let failure as ProbeFailure {
            guard client == .codex, failure.suggestsWrongEndpoint else { throw failure.error }
            // Responses 端点像是不存在。再探一次 Chat Completions，仅仅是为了分辨
            // “中转站只提供 Chat Completions” 和 “这条线路整个不通”，好给出能照着办的提示。
            // Codex 已经移除 wire_api = "chat"，所以探通了也不能写进配置。
            do {
                try await probe(configuration, baseURL: baseURL, client: client, endpoint: .chatCompletions)
            } catch {
                throw failure.error
            }
            throw RelaySetupError.incompatible(
                "该中转站只提供 \(ProbeEndpoint.chatCompletions.name) 接口，没有 \(ProbeEndpoint.responses.name) 接口。"
                    + "Codex 已移除 wire_api = \"chat\" 支持，请改用提供 Responses 接口的中转线路。"
            )
        }
    }

    private func probe(
        _ configuration: RelayConfiguration,
        baseURL: URL,
        client: ClientKind,
        endpoint: ProbeEndpoint
    ) async throws {
        var request = URLRequest(url: endpointURL(baseURL: baseURL, client: client, endpoint: endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let protocolName: String
        let body: [String: Any]
        switch client {
        case .claude:
            protocolName = client.protocolName
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": configuration.model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "Reply with OK"]]
            ]
        case .codex:
            protocolName = endpoint.name
            switch endpoint {
            case .responses:
                body = [
                    "model": configuration.model,
                    "input": "Reply with OK",
                    "max_output_tokens": 16
                ]
            case .chatCompletions:
                body = [
                    "model": configuration.model,
                    "max_tokens": 16,
                    "messages": [["role": "user", "content": "Reply with OK"]]
                ]
            }
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ProbeFailure(error: .network(error.localizedDescription))
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await send(request)
        } catch let error as RelaySetupError {
            throw ProbeFailure(error: error)
        } catch {
            throw ProbeFailure(error: .network(error.localizedDescription))
        }

        guard (200..<300).contains(http.statusCode) else {
            let detail = failureDetail(from: data, statusCode: http.statusCode)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProbeFailure(error: .incompatible("API Key 未通过验证，\(detail)"))
            }
            throw ProbeFailure(
                error: .incompatible("\(protocolName) 请求失败，\(detail)"),
                suggestsWrongEndpoint: Self.wrongEndpointStatusCodes.contains(http.statusCode)
            )
        }
    }

    /// 这些状态码更像“这个端点不存在／不认识这个请求体”，值得换另一个端点再确认一次。
    /// 401/403 是鉴权问题，5xx 是服务端故障，都不在其中。
    private static let wrongEndpointStatusCodes: Set<Int> = [400, 404, 405, 415, 422, 501]

    private struct ProbeFailure: Error {
        let error: RelaySetupError
        var suggestsWrongEndpoint = false
    }

    /// 连通性探测用到的 OpenAI 端点。仅用于探测和诊断，绝不写进客户端配置：
    /// Codex 只接受 wire_api = "responses"，写入 "chat" 会让它无法解析 config.toml。
    enum ProbeEndpoint {
        case responses
        case chatCompletions

        var name: String {
            switch self {
            case .responses: "OpenAI Responses"
            case .chatCompletions: "OpenAI Chat Completions"
            }
        }

        var path: String {
            switch self {
            case .responses: "responses"
            case .chatCompletions: "chat/completions"
            }
        }
    }

    func fetchModels(baseURL value: String, apiKey: String) async throws -> ModelCatalog {
        let baseURL = try validatedBaseURL(value.trimmingCharacters(in: .whitespacesAndNewlines))
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw RelaySetupError.missingAPIKey }

        var request = URLRequest(url: modelsURL(baseURL: baseURL))
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            let (data, http) = try await send(request)
            guard (200..<300).contains(http.statusCode) else {
                let detail = failureDetail(from: data, statusCode: http.statusCode)
                throw RelaySetupError.incompatible("模型列表读取失败，\(detail)")
            }
            let catalog = try parseModels(data)
            guard !catalog.models.isEmpty else {
                throw RelaySetupError.incompatible("模型列表为空，可直接手动输入模型名。")
            }
            return catalog
        } catch let error as RelaySetupError {
            throw error
        } catch {
            throw RelaySetupError.network(error.localizedDescription)
        }
    }

    func validatedBaseURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty,
              scheme == "https" || scheme == "http"
        else { throw RelaySetupError.invalidURL }
        let localHosts = ["localhost", "127.0.0.1", "::1"]
        if scheme == "http", !localHosts.contains(host.lowercased()) {
            throw RelaySetupError.insecureURL
        }
        return url
    }

    func endpointURL(
        baseURL: URL,
        client: ClientKind,
        endpoint: ProbeEndpoint = .responses
    ) -> URL {
        if client == .claude,
           let runtimeBaseURL = URL(string: ClaudeConfigurationAdapter.runtimeBaseURL(baseURL.absoluteString)) {
            return appendingAPIPath("v1/messages", to: runtimeBaseURL)
        }

        let endpointName = client == .claude ? "messages" : endpoint.path
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/\(endpointName)") {
            components.path = path
        } else if path.hasSuffix("/v1") {
            components.path = path + "/\(endpointName)"
        } else {
            components.path = path + "/v1/\(endpointName)"
        }
        return components.url!
    }

    private func appendingAPIPath(_ apiPath: String, to baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/" + apiPath
        return components.url!
    }

    func modelsURL(baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/models") {
            components.path = path
        } else if path.hasSuffix("/v1") {
            components.path = path + "/models"
        } else {
            components.path = path + "/v1/models"
        }
        return components.url!
    }

    func parseModels(_ data: Data) throws -> ModelCatalog {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RelaySetupError.incompatible("模型列表不是有效的 JSON。")
        }

        let rawItems: [Any]
        if let object = value as? [String: Any] {
            rawItems = object["data"] as? [Any] ?? object["models"] as? [Any] ?? []
        } else {
            rawItems = value as? [Any] ?? []
        }

        var capabilities: [String: Bool] = [:]
        for item in rawItems {
            let identifier: String?
            let supports1M: Bool
            if let name = item as? String {
                identifier = name
                supports1M = false
            } else if let object = item as? [String: Any] {
                identifier = object["id"] as? String ?? object["name"] as? String
                supports1M = object["supports1m"] as? Bool
                    ?? object["supports_1m"] as? Bool
                    ?? false
            } else {
                continue
            }

            guard let identifier else { continue }
            let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            capabilities[normalized] = (capabilities[normalized] ?? false) || supports1M
        }
        let models = capabilities.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return ModelCatalog(
            models: models,
            oneMillionContextModels: Set(capabilities.compactMap { $0.value ? $0.key : nil })
        )
    }

    /// 网关抽风（502/504/554 之类）会返回空响应体，重试一次通常就能过，
    /// 不该让用户看到“中转站不兼容”。
    private func send(_ request: URLRequest, attempts: Int = 2) async throws -> (Data, HTTPURLResponse) {
        let attempts = max(1, attempts)
        for attempt in 1...attempts {
            do {
                let (data, response) = try await sender(request)
                guard let http = response as? HTTPURLResponse else {
                    throw RelaySetupError.network("服务器返回了无法识别的响应。")
                }
                if Self.isTransient(status: http.statusCode), attempt < attempts {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                return (data, http)
            } catch let error as RelaySetupError {
                throw error
            } catch {
                guard Self.isTransient(error: error), attempt < attempts else { throw error }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        throw RelaySetupError.network("请求未能完成。")
    }

    private static func isTransient(status code: Int) -> Bool {
        if code == 408 || code == 425 { return true }
        if code == 501 || code == 505 { return false }
        return code >= 500
    }

    private static func isTransient(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .timedOut || urlError.code == .networkConnectionLost
    }

    /// 状态码始终保留：中转站在出错时经常回一个空 body，只报文字会得到一句没有信息的错误。
    private func failureDetail(from data: Data, statusCode: Int) -> String {
        guard let message = responseMessage(from: data) else { return "HTTP \(statusCode)" }
        return "\(message)（HTTP \(statusCode)）"
    }

    private func responseMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nonEmpty(String(data: data.prefix(240), encoding: .utf8))
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return nonEmpty(String(message.prefix(240)))
        }
        if let message = object["message"] as? String {
            return nonEmpty(String(message.prefix(240)))
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
