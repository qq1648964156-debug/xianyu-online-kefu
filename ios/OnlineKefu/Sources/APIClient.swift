import Foundation

/// 极简 API 客户端：URLSession + async/await，不引第三方库。
/// 所有请求带 Bearer token；失败时把后端 `message` 原样抛给界面（比"请求失败"有用得多）。
final class APIClient {
    static let shared = APIClient()

    /// 服务地址（可在设置里改，存 UserDefaults）
    var baseURL: URL = AppSettings.serverURL
    /// 登录后拿到的 token（access，30 分钟过期）
    var token: String?
    /// 刷新令牌（7 天），过期后用它换新 access
    var refreshToken: String?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        return URLSession(configuration: cfg)
    }()

    private let decoder = JSONDecoder()

    // MARK: - 基础请求

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await request(path, method: "GET", query: query, body: nil)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> T {
        try await request(path, method: "POST", query: [:], body: body)
    }

    /// 不走 `{success,data}` 包装的接口（例如账号列表：data 是数组、total 在顶层）
    func rawGet<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw APIError(message: "服务地址不合法")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError(message: "服务地址不合法") }
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401, await refreshAccessToken() {
            req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
            (data, resp) = try await session.data(for: req)
        }
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            throw APIError(message: "登录已过期，请重新登录")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // 尽量把后端的错误信息透出来
            if let env = try? decoder.decode(APIEnvelope<EmptyData>.self, from: data),
               let msg = env.message {
                throw APIError(message: msg)
            }
            throw APIError(message: "返回数据格式不对")
        }
    }

    private func request<T: Decodable>(_ path: String,
                                       method: String,
                                       query: [String: String],
                                       body: [String: Any]?) async throws -> T {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw APIError(message: "服务地址不合法")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError(message: "服务地址不合法") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        var (data, resp) = try await session.data(for: req)
        guard var http = resp as? HTTPURLResponse else {
            throw APIError(message: "网络异常")
        }
        // access token 只有 30 分钟，过期后用 refresh_token 换一次再重试
        if http.statusCode == 401, await refreshAccessToken() {
            req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
            (data, resp) = try await session.data(for: req)
            guard let retried = resp as? HTTPURLResponse else {
                throw APIError(message: "网络异常")
            }
            http = retried
        }
        if http.statusCode == 401 {
            throw APIError(message: "登录已过期，请重新登录")
        }

        // 先按成功包装解一次；失败时尽量把后端的 message 带出来
        if let env = try? decoder.decode(APIEnvelope<T>.self, from: data) {
            if env.success == false {
                throw APIError(message: env.message ?? "请求失败")
            }
            if let value = env.data { return value }
        }
        // 部分接口的 data 是直接对象（不再套一层），兜底解一次
        if let value = try? decoder.decode(T.self, from: data) {
            return value
        }
        if let env = try? decoder.decode(APIEnvelope<EmptyData>.self, from: data),
           env.success == false {
            throw APIError(message: env.message ?? "请求失败")
        }
        throw APIError(message: "返回数据格式不对")
    }

    /// 用 refresh_token 换新的 access token。
    /// 后端约定：POST /api/v1/auth/refresh，**refresh_token 放在 Authorization 头里**（不是 body）。
    @discardableResult
    func refreshAccessToken() async -> Bool {
        let rt = (AppSettings.refreshToken ?? refreshToken ?? "").trimmingCharacters(in: .whitespaces)
        guard !rt.isEmpty else { return false }
        guard let url = URL(string: baseURL.absoluteString + "/api/v1/auth/refresh") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(rt)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await session.data(for: req),
              let resp = try? decoder.decode(LoginResponse.self, from: data),
              let result = resp.result else {
            return false
        }
        token = result.token
        refreshToken = result.refreshToken ?? rt
        AppSettings.token = result.token
        AppSettings.refreshToken = self.refreshToken
        return true
    }

    // MARK: - 业务接口

    func login(username: String, password: String) async throws -> LoginResult {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1/auth/login"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = nil
        guard let url = comps?.url else { throw APIError(message: "服务地址不合法") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])

        let (data, _) = try await session.data(for: req)
        let resp = try decoder.decode(LoginResponse.self, from: data)
        guard let result = resp.result else {
            throw APIError(message: resp.message ?? "登录失败")
        }
        token = result.token
        refreshToken = result.refreshToken
        return result
    }

    func accounts() async throws -> [ChatAccount] {
        let res: AccountsResponse = try await rawGet("api/v1/chat-new/accounts",
                                                     query: ["page": "1", "page_size": "50"])
        if res.success == false { throw APIError(message: res.message ?? "获取账号失败") }
        return res.data ?? []
    }

    func conversations(accountId: String, cursor: Int?) async throws -> ConversationPage {
        var q = ["limit": "20"]
        if let cursor { q["cursor"] = String(cursor) }
        return try await get("api/v1/chat-new/conversations/\(accountId)", query: q)
    }

    func messages(accountId: String, cid: String, cursor: Int?) async throws -> MessagePage {
        var q = ["limit": "20"]
        if let cursor { q["cursor"] = String(cursor) }
        return try await get("api/v1/chat-new/messages/\(accountId)/\(cid)", query: q)
    }

    func sendMessage(accountId: String, cid: String, toUserId: String, text: String) async throws {
        struct Ack: Decodable { let success: Bool?; let message: String? }
        let ack: Ack = try await post("api/v1/chat-new/send-message/\(accountId)",
                                      body: ["cid": cid, "toUserId": toUserId, "text": text])
        if ack.success == false {
            throw APIError(message: ack.message ?? "发送失败")
        }
    }

    func quickPhrases() async throws -> [QuickPhrase] {
        try await get("api/v1/chat-new/quick-phrases")
    }

    // MARK: - 快捷短语增删改（网页端同一套接口）

    @discardableResult
    func createQuickPhrase(title: String, content: String) async throws -> QuickPhrase? {
        struct R: Decodable { let success: Bool?; let message: String?; let data: QuickPhrase? }
        let r: R = try await post("api/v1/chat-new/quick-phrases",
                                  body: ["title": title, "content": content])
        if r.success == false { throw APIError(message: r.message ?? "新增失败") }
        return r.data
    }

    @discardableResult
    func updateQuickPhrase(id: Int, title: String, content: String) async throws -> QuickPhrase? {
        struct R: Decodable { let success: Bool?; let message: String?; let data: QuickPhrase? }
        let r: R = try await rawSend("PUT", "api/v1/chat-new/quick-phrases/\(id)",
                                     body: ["title": title, "content": content])
        if r.success == false { throw APIError(message: r.message ?? "保存失败") }
        return r.data
    }

    func deleteQuickPhrase(id: Int) async throws {
        struct R: Decodable { let success: Bool?; let message: String? }
        let r: R = try await rawSend("DELETE", "api/v1/chat-new/quick-phrases/\(id)", body: nil)
        if r.success == false { throw APIError(message: r.message ?? "删除失败") }
    }

    // MARK: - 会话信息（买家订单 / 咨询商品）

    func customerOrders(accountId: String, buyerId: String, chatId: String) async throws -> [CustomerOrder] {
        try await get("api/v1/chat-new/customer-orders/\(accountId)/\(buyerId)",
                      query: ["chat_id": chatId])
    }

    func consultItem(accountId: String, cid: String) async throws -> ConsultItem? {
        struct R: Decodable { let success: Bool?; let message: String?; let data: ConsultItem? }
        let r: R = try await rawSend("GET", "api/v1/chat-new/consult-item/\(accountId)/\(cid)", body: nil)
        if r.success == false { throw APIError(message: r.message ?? "获取咨询商品失败") }
        return r.data
    }

    /// 通用发送（PUT/DELETE 等）：后端有的接口不是包在 data 里，直接解 R
    private func rawSend<T: Decodable>(_ method: String, _ path: String,
                                       body: [String: Any]?) async throws -> T {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else {
            throw APIError(message: "服务地址不合法")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        var (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401, await refreshAccessToken() {
            req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
            (data, resp) = try await session.data(for: req)
        }
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            throw APIError(message: "登录已过期，请重新登录")
        }
        return try decoder.decode(T.self, from: data)
    }
}

struct EmptyData: Decodable {}

enum AppSettings {
    private static let serverKey = "xy.serverURL"
    private static let tokenKey = "xy.token"
    private static let refreshKey = "xy.refreshToken"
    private static let nameKey = "xy.username"

    static var serverURL: URL {
        get {
            let raw = UserDefaults.standard.string(forKey: serverKey) ?? "http://127.0.0.1:9000"
            return URL(string: raw) ?? URL(string: "http://127.0.0.1:9000")!
        }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: serverKey) }
    }

    static var token: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    /// 网页版 WebView 注入登录态要用到 refresh_token（否则 30 分钟后网页端掉登录）
    static var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: refreshKey) }
        set { UserDefaults.standard.set(newValue, forKey: refreshKey) }
    }

    static var username: String? {
        get { UserDefaults.standard.string(forKey: nameKey) }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    static func clearLogin() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: refreshKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }
}
