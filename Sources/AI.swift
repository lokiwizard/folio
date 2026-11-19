import Foundation

enum Provider: String, CaseIterable, Codable, Identifiable {
    case openAI = "OpenAI", anthropic = "Anthropic", google = "Google Gemini", deepSeek = "DeepSeek"
    case qwen = "阿里云百炼", kimi = "月之暗面", glm = "智谱", doubao = "火山方舟", custom = "自定义 OpenAI 兼容接口"
    var id: Self { self }
    var endpoints: [(String, String)] {
        switch self {
        case .openAI: [(L("默认"), "https://api.openai.com/v1")]
        case .anthropic: [(L("默认"), "https://api.anthropic.com/v1")]
        case .google: [(L("默认"), "https://generativelanguage.googleapis.com/v1beta")]
        case .deepSeek: [(L("默认"), "https://api.deepseek.com")]
        case .qwen: [(L("北京"), "https://dashscope.aliyuncs.com/compatible-mode/v1"),
                     (L("新加坡"), "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")]
        case .kimi: [(L("中国"), "https://api.moonshot.cn/v1"), (L("国际"), "https://api.moonshot.ai/v1")]
        case .glm: [(L("中国"), "https://open.bigmodel.cn/api/paas/v4"), (L("国际"), "https://api.z.ai/api/paas/v4")]
        case .doubao: [(L("北京"), "https://ark.cn-beijing.volces.com/api/v3")]
        case .custom: [(L("自定义"), "")]
        }
    }
    var models: [String] {
        switch self {
        case .openAI: ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6-luna"]
        case .anthropic: ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-2"]
        case .google: ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .deepSeek: ["deepseek-flash", "deepseek-v4-pro"]
        case .qwen: ["qwen-plus", "qwen-max"]
        case .kimi: ["kimi-k2.5"]
        case .glm: ["glm-4.7"]
        case .doubao, .custom: []
        }
    }
}

struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var provider: Provider
    var base: String
    var model: String
    var modelCatalog: [String]?
    var savedModels: [String]?
    var credentialID: UUID?
    var keyID: UUID { credentialID ?? id } // Older versions stored the key under the profile ID.
    init(_ provider: Provider) {
        self.provider = provider
        base = provider.endpoints[0].1
        model = provider.models.first ?? ""
    }
    var title: String { model.isEmpty ? L(provider.rawValue) : "\(L(provider.rawValue)) · \(model)" }
    var modelChoices: [String] {
        Set((modelCatalog ?? provider.models) + (savedModels ?? []) + [model]).filter { !$0.isEmpty }.sorted()
    }
    func sharesService(with other: Profile) -> Bool {
        guard provider == other.provider, let address = serviceAddress else { return false }
        return address == other.serviceAddress
    }
    private var serviceAddress: String? {
        guard let url = try? validatedBase(requireModel: false),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        return parts.string
    }
    func validatedBase(requireModel: Bool = true) throws -> URL {
        guard let parts = URLComponents(string: base), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url
        else { throw ReaderError(L("请填写有效的 HTTPS 服务地址。")) }
        guard !requireModel || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReaderError(L("请输入模型 ID。")) }
        return url
    }
}

struct ChatAttachment: Identifiable {
    enum Content {
        case passage(text: String, pages: [Int], tag: UUID?)
        case clip(Anchor)
        case loading
        case file(ChatFile)
    }
    let id: UUID
    let title: String?
    let content: Content
    init(id: UUID, name: String, content: Content) { self.id = id; title = name; self.content = content }
    init(_ excerpt: Excerpt) {
        id = excerpt.id
        title = excerpt.customTitle
        content = .passage(text: excerpt.text, pages: Set(excerpt.lines.map(\.page)).sorted(), tag: excerpt.tag)
    }
    init(_ pin: Pin) {
        id = pin.id
        title = pin.customTitle
        content = .clip(pin.source)
    }
    var label: String {
        if let title { return title }
        switch content {
        case let .passage(text, pages, _): return text.isEmpty ? pages.map(pageName).joined(separator: ", ") : text
        case let .clip(anchor): return pageName(anchor.page)
        case .loading, .file: return L("文件")
        }
    }
}

struct ChatLine: Codable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
    var displayText: String?
    var fileNames: [String]?
    var includesSource: Bool?
    var images: [Data]?
    var selection: Citation?
    var sourceFormatVersion: Int?
    var createdAt: Date? = Date()

    var bubbleText: String {
        guard let files = fileNames, !files.isEmpty else { return text }
        return (["📎 " + files.joined(separator: " · ")] + (text.isEmpty ? [] : [text])).joined(separator: "\n")
    }
    var forDisplay: ChatLine {
        ChatLine(id: id, role: role, text: displayText ?? text, fileNames: fileNames, selection: selection, createdAt: createdAt)
    }

    // Old requests stored card notes and PDF extracts in one string. Only
    // replay independently identified fields when continuing those chats.
    var forFollowUp: ChatLine {
        guard role == "user", sourceFormatVersion == nil, let displayText else { return self }
        var safe = self
        safe.text = [selection?.pages.map(pageName).joined(separator: ", "), selection?.text, displayText]
            .compactMap { $0 }.joined(separator: "\n\n")
        safe.includesSource = false
        safe.sourceFormatVersion = 2
        return safe
    }
}
struct PaperChat: Codable, Identifiable {
    var id = UUID()
    var messages: [ChatLine] = []
    var wholePaper = true
    var citation: Citation?
    var title: String {
        if let title = messages.first?.displayText, !title.isEmpty { return title }
        return messages.first?.fileNames?.first ?? L("新对话")
    }
}

private final class DirectOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AIClient {
    static func request(profile: Profile, key: String, history: [ChatLine], streaming: Bool = false) throws -> URLRequest {
        let base = try profile.validatedBase()
        guard !key.isEmpty else { throw ReaderError(L("请先填写 API Key。")) }
        var url: URL
        var body: [String: Any]
        var headers: [String: String] = [:]
        let responses = profile.provider == .openAI && profile.model.hasPrefix("gpt-6")
        let messages: [[String: Any]] = history.map { line in
            if profile.provider == .google {
                var parts: [[String: Any]] = [["text": line.text]]
                for image in line.images ?? [] { parts.append(["inlineData": ["mimeType": "image/jpeg", "data": image.base64EncodedString()]]) }
                return ["role": line.role == "assistant" ? "model" : "user", "parts": parts]
            }
            guard let images = line.images, !images.isEmpty else { return ["role": line.role, "content": line.text] }
            var parts: [[String: Any]] = [["type": responses ? "input_text" : "text", "text": line.text]]
            for image in images {
                let encoded = image.base64EncodedString()
                if profile.provider == .anthropic {
                    parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": encoded]])
                } else if responses {
                    parts.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + encoded])
                } else {
                    parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + encoded]])
                }
            }
            return ["role": line.role, "content": parts]
        }
        switch profile.provider {
        case .openAI where profile.model.hasPrefix("gpt-6"):
            url = base.appendingPathComponent("responses")
            headers = ["Authorization": "Bearer " + key]
            body = ["model": profile.model, "input": messages, "store": false]
        case .anthropic:
            url = base.appendingPathComponent("messages")
            headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
            body = ["model": profile.model, "max_tokens": 4096, "messages": messages]
        case .google:
            guard profile.model.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { throw ReaderError(L("请输入 Gemini 模型 ID。")) }
            url = base.appendingPathComponent("models/\(profile.model):generateContent")
            if streaming {
                url = base.appendingPathComponent("models/\(profile.model):streamGenerateContent")
                    .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])
            }
            headers = ["x-goog-api-key": key]
            body = ["contents": messages]
        default:
            url = base.appendingPathComponent("chat/completions")
            headers = ["Authorization": "Bearer " + key]
            body = ["model": profile.model, "messages": messages]
        }
        if streaming && profile.provider != .google { body["stream"] = true }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func decode(_ data: Data, provider: Provider) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let answer: String?
        switch provider {
        case .openAI where json?["output"] != nil:
            let output = json?["output"] as? [[String: Any]] ?? []
            answer = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined()
        case .anthropic:
            answer = (json?["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .google:
            let content = (json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
            answer = (content?["parts"] as? [[String: Any]])?.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        default:
            let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            answer = message?["content"] as? String
        }
        guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReaderError(L("服务未返回可显示的文本，请检查模型或重试。")) }
        return answer
    }
    static func models(profile: Profile, key: String, configuration: URLSessionConfiguration = .ephemeral) async throws -> [String] {
        let base = try profile.validatedBase(requireModel: false)
        guard !key.isEmpty else { throw ReaderError(L("请先填写 API Key。")) }
        let session = URLSession(configuration: configuration, delegate: DirectOnly(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var result = Set<String>(), seen = Set<String>()
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            var url = base.appendingPathComponent("models")
            if let cursor {
                url = url.appending(queryItems: [URLQueryItem(name: profile.provider == .google ? "pageToken" : "after_id", value: cursor)])
            }
            var req = URLRequest(url: url)
            switch profile.provider {
            case .anthropic:
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .google: req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            default: req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: req)
            try validate(response)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if profile.provider == .google {
                for item in json?["models"] as? [[String: Any]] ?? [] {
                    if (item["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true,
                       let name = item["name"] as? String { result.insert(String(name.dropFirst(name.hasPrefix("models/") ? 7 : 0))) }
                }
                cursor = json?["nextPageToken"] as? String
            } else {
                for item in json?["data"] as? [[String: Any]] ?? [] {
                    if let id = item["id"] as? String { result.insert(id) }
                }
                cursor = json?["has_more"] as? Bool == true ? json?["last_id"] as? String : nil
            }
            if let cursor, !seen.insert(cursor).inserted { break }
        } while cursor != nil
        guard !result.isEmpty else { throw ReaderError(bilingual("服务没有返回模型列表。", "The service returned no models.")) }
        return result.sorted()
    }

    static func streamEvent(_ data: Data, provider: Provider) throws -> (text: String, done: Bool) {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let type = object["type"] as? String
        if object["error"] != nil || ["error", "response.failed", "response.incomplete"].contains(type ?? "") {
            throw ReaderError(bilingual("模型未完成回答，请重试。", "The model did not complete its response. Please retry."))
        }
        if type == "response.output_text.delta" { return (object["delta"] as? String ?? "", false) }
        if type == "response.completed" || type == "message_stop" { return ("", true) }
        if provider == .anthropic {
            let delta = object["delta"] as? [String: Any]
            return (delta?["text"] as? String ?? "", false)
        }
        if provider == .google {
            let candidate = (object["candidates"] as? [[String: Any]])?.first
            let content = candidate?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            return (parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined(), candidate?["finishReason"] != nil)
        }
        let choice = (object["choices"] as? [[String: Any]])?.first
        let delta = choice?["delta"] as? [String: Any]
        return (delta?["content"] as? String ?? "", choice?["finish_reason"] is String)
    }

    static func stream(_ profile: Profile, _ history: [ChatLine], key: String, configuration: URLSessionConfiguration = .ephemeral, update: @MainActor (String) -> Void) async throws -> String {
        let req = try request(profile: profile, key: key, history: history, streaming: true)
        let session = URLSession(configuration: configuration, delegate: DirectOnly(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: req)
        try validate(response)
        var answer = "", finished = false
        var lastUpdate = Date.distantPast
        if response.mimeType == "application/json" {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return try decode(data, provider: profile.provider)
        }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            try Task.checkCancellation()
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value == "[DONE]" { finished = true; break }
            let event = try streamEvent(Data(value.utf8), provider: profile.provider)
            answer += event.text
            if !event.text.isEmpty && Date().timeIntervalSince(lastUpdate) >= 0.05 {
                await update(answer)
                lastUpdate = Date()
            }
            if event.done { finished = true; break }
        }
        guard finished, !answer.isEmpty else { throw ReaderError(bilingual("回答中断或为空，请重试。", "The response was interrupted or empty. Please retry.")) }
        return answer
    }

    static func send(profile: Profile, key: String, history: [ChatLine]) async throws -> String {
        let request = try request(profile: profile, key: key, history: history)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: DirectOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decode(data, provider: profile.provider)
    }
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let hint: String
            switch status {
            case 401, 403: hint = L("请检查 API Key、地域及模型权限。")
            case 404: hint = L("请检查服务地址与模型 ID。")
            case 429: hint = L("请检查额度或稍后重试。")
            default: hint = L("请检查配置或稍后重试。")
            }
            throw ReaderError(bilingual("服务返回 HTTP \(status)。", "HTTP \(status). ") + hint)
        }
    }
}
