import Foundation

/// 在线聊天 WebSocket 客户端（替代轮询）
///
/// 背景：1.3.0 为了"自动刷新"每 20 秒调一次 `/conversations`，而这个接口是**实时打闲鱼**的，
/// 请求一叠加就把整站拖垮（用户反馈"功能全报错"），所以 1.3.1 把轮询撤了 ——
/// 结果又变成"消息不会自动刷新"。
///
/// 正确做法是跟网页端一样走推送：后端 `/api/v1/chat-new/ws/{account_id}?token=...`
/// 收到买家消息会实时下发 `{"event":"new_message","cid":...,"message":{...}}`。
/// 这里负责：连接、心跳、断线指数退避重连、把事件回调给上层。
final class ChatWebSocketClient {
    enum Event {
        case connected
        case disconnected
        case newMessage(cid: String, message: ChatMessage)
    }

    var onEvent: ((Event) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var attempt = 0
    private var closedByUser = false

    private var serverURL: URL?
    private var accountId = ""
    private var token = ""
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    var isConnected: Bool { task?.state == .running }

    // MARK: - 生命周期

    func connect(serverURL: URL, accountId: String, token: String) {
        guard let url = Self.wsURL(serverURL: serverURL, accountId: accountId, token: token) else { return }
        // 同一个账号同一地址已连着就不重连（避免切页面反复建连）
        if isConnected, self.accountId == accountId, self.serverURL == serverURL { return }

        disconnect(byUser: true)
        closedByUser = false
        self.serverURL = serverURL
        self.accountId = accountId
        self.token = token

        task = session.webSocketTask(with: url)
        task?.resume()
        startPing()
        receive()
    }

    func disconnect(byUser: Bool = true) {
        if byUser { closedByUser = true }
        reconnectWork?.cancel(); reconnectWork = nil
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        attempt = 0
    }

    // MARK: - 内部

    private static func wsURL(serverURL: URL, accountId: String, token: String) -> URL? {
        guard var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        var path = comps.path
        if path.hasSuffix("/") { path.removeLast() }
        // ⚠️ 这里**不能再手动 percent-encode**：URLComponents.path 自己会编码，
        // 提前编码会变成双重编码（中文账号名 → %25E4%25BC...），
        // 后端拿到编码串查不到账号，WS 注册到错误的 key 上 → 收不到任何推送（2026-11-23 实锤）。
        comps.path = path + "/api/v1/chat-new/ws/\(accountId)"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url
    }

    private func startPing() {
        dispatchPrecondition(condition: .onQueue(.main))
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self, let task = self.task else { return }
            task.send(.string(#"{"type":"ping"}"#)) { _ in }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            // URLSession 回调在后台线程，统一切到主线程处理状态
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive()          // 继续收
                case .failure:
                    self.handleDrop()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }

        switch event {
        case "connected":
            attempt = 0
            onEvent?(.connected)
        case "pong":
            break
        case "new_message":
            guard let cid = obj["cid"] as? String,
                  let m = obj["message"] as? [String: Any] else { return }
            let msg = ChatMessage(
                messageId: (m["messageId"] as? String) ?? UUID().uuidString,
                senderName: (m["senderName"] as? String) ?? "",
                isSelf: (m["isSelf"] as? Bool) ?? false,
                type: (m["type"] as? String) ?? "text",
                text: (m["text"] as? String) ?? "",
                images: (m["images"] as? [String]) ?? [],
                time: (m["time"] as? Double) ?? (Double(m["time"] as? Int ?? 0)),
                senderId: (m["senderId"] as? String) ?? ""
            )
            onEvent?(.newMessage(cid: cid, message: msg))
        default:
            break
        }
    }

    private func handleDrop() {
        task = nil
        pingTimer?.invalidate(); pingTimer = nil
        onEvent?(.disconnected)
        guard !closedByUser else { return }
        attempt += 1
        // 指数退避：2/4/8/16/30 秒，避免后端挂了还在疯狂重连
        let delay = min(30, pow(2.0, Double(min(attempt, 5))))
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.serverURL, !self.accountId.isEmpty else { return }
            self.connect(serverURL: url, accountId: self.accountId, token: self.token)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
