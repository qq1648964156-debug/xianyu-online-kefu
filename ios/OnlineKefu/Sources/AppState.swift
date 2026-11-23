import Foundation
import SwiftUI

@MainActor
enum AppTab: Hashable { case messages, web, accounts, settings }

final class AppState: ObservableObject {
    /// 后台刷新（BGAppRefreshTask）与界面共用同一份状态
    static let shared = AppState()

    @Published var token: String? = AppSettings.token
    @Published var refreshToken: String? = AppSettings.refreshToken
    @Published var username: String? = AppSettings.username
    @Published var accounts: [ChatAccount] = []
    @Published var selectedAccount: ChatAccount?
    @Published var conversations: [Conversation] = []
    @Published var messages: [ChatMessage] = []
    @Published var quickPhrases: [QuickPhrase] = []

    @Published var loadingAccounts = false
    @Published var loadingConversations = false
    @Published var loadingMessages = false
    @Published var sending = false
    @Published var errorText: String?
    /// 当前 Tab（供"在网页版打开订单/商品"这类跳转使用）
    @Published var selectedTab: AppTab = .messages
    /// 待网页版打开的路径（如 "/orders"），WebConsoleView 消费后清空
    @Published var pendingWebPath: String?
    /// 实时通道是否在线（WebSocket 连上 = true）
    @Published var realtimeConnected = false
    /// 当前正在看的会话（收到推送时判断要不要追加到聊天窗口）
    @Published var viewingCID: String?
    /// 会话 → 订单状态标签（key: "账号|买家ID" 与 "账号|#会话ID"）
    @Published var orderTags: [String: ConversationOrderTag] = [:]
    private var tagTimer: Timer?

    /// 取某个会话的订单标签（先按买家ID，再按会话ID兜底 —— 订单里的 chat_id 大量为空）
    func orderTag(for conv: Conversation) -> ConversationOrderTag? {
        guard let account = selectedAccount else { return nil }
        if !conv.otherUserId.isEmpty,
           let hit = orderTags["\(account.accountId)|\(conv.otherUserId)"] { return hit }
        let normCid = conv.cid.split(separator: "@").first.map(String.init) ?? conv.cid
        return orderTags["\(account.accountId)|#\(normCid)"]
    }

    /// 拉订单标签（后端只读本地库，60 秒一次也不打闲鱼）
    func refreshOrderTags() async {
        guard !accounts.isEmpty else { return }
        do {
            let ids = accounts.map(\.accountId)
            let tags = try await api.orderTags(accountIds: ids)
            var map: [String: ConversationOrderTag] = [:]
            for t in tags {
                if !t.buyerId.isEmpty { map["\(t.accountId)|\(t.buyerId)"] = t }
                if !t.chatId.isEmpty {
                    let norm = t.chatId.split(separator: "@").first.map(String.init) ?? t.chatId
                    map["\(t.accountId)|#\(norm)"] = t
                }
            }
            orderTags = map
        } catch {
            // 标签只是锦上添花，失败保持上一次结果
        }
    }

    private func startTagTimer() {
        guard tagTimer == nil else { return }
        tagTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshOrderTags() }
        }
    }
    private var errorDismissToken = 0

    private var convCursor: Int?
    private var msgCursor: Int?
    private var msgCid: String?
    private let api = APIClient.shared

    var isLoggedIn: Bool { token?.isEmpty == false }

    init() {
        api.baseURL = AppSettings.serverURL
        api.token = AppSettings.token
        api.refreshToken = AppSettings.refreshToken
    }

    // MARK: - 错误与未读

    /// 统一处理错误：**用户切页/重进导致 URLSession 取消（-999 cancelled）不是故障**，
    /// 以前会把它当网络错误弹红条，于是会话列表顶上一直挂着 "cancelled"（2026-11-22 实拍）。
    func handle(_ error: Error) {
        if Self.isCancellation(error) { return }
        let message = (error as? APIError)?.message ?? error.localizedDescription
        // 自动续期失败 = 真的过期（refresh 也失效），退回登录页而不是留一个"什么都点不动"的界面
        if message.contains("登录已过期") {
            logout()
            errorText = message
            return
        }
        errorText = message
        scheduleErrorDismiss()
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if error is CancellationError { return true }
        let text = ns.localizedDescription.lowercased()
        return text == "cancelled" || text == "canceled" || text.contains("已取消")
    }

    /// 红条 6 秒自动消失（也支持点一下手动清）
    private func scheduleErrorDismiss() {
        errorDismissToken &+= 1
        let token = errorDismissToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.errorDismissToken == token else { return }
            self.errorText = nil
        }
    }

    func clearError() {
        errorDismissToken &+= 1
        errorText = nil
    }

    /// 打开会话即视为已读（网页端也是本地水位，不需要后端接口）
    /// 进入会话即记录已读水位
    ///
    /// ⚠️ 关键：**不管当前 unreadCount 是不是 0，都要写水位**。
    /// 1.4.0 的实现里带了个 `unreadCount > 0` 的 guard：如果这个会话刚刚被本地清零过（或本来就是 0），
    /// 就不写水位；而后端没有"标记已读"接口，下次刷新列表照样返回未读 1 → 红点又冒出来
    /// （2026-11-23 用户反馈"气泡一刷新就出来"）。
    /// `latestMessageTime` 用进入会话后真正加载到的最新消息时间，避免列表里的时间戳偏旧。
    func markRead(_ conversation: Conversation, latestMessageTime: Double? = nil) {
        guard let account = selectedAccount else { return }
        let time = max(conversation.lastMessageTime, latestMessageTime ?? 0)
        ReadStore.mark(account: account.accountId, cid: conversation.cid,
                       time: time, summary: conversation.lastMessageSummary)
        if let idx = conversations.firstIndex(where: { $0.cid == conversation.cid }),
           conversations[idx].unreadCount > 0 {
            conversations[idx].unreadCount = 0
            NotificationManager.shared.updateBadge(totalUnread)
        }
    }

    /// 渲染层判断：这个会话是否已读（不依赖刷新流程是否执行过 apply）
    func isRead(_ conversation: Conversation) -> Bool {
        guard let account = selectedAccount else { return false }
        return ReadStore.isRead(account: account.accountId, cid: conversation.cid,
                                time: conversation.lastMessageTime,
                                summary: conversation.lastMessageSummary)
    }

    /// 一键已读：把当前列表全部置为已读（本地水位持久化，刷新后也不会回来）
    func markAllRead() {
        guard let account = selectedAccount else { return }
        ReadStore.markAll(account: account.accountId, conversations: conversations)
        for i in conversations.indices { conversations[i].unreadCount = 0 }
        NotificationManager.shared.clearBadge()
    }

    /// 跳到「网页版」并打开指定路径（订单管理 / 商品管理 / 智能客服…）
    func openInWeb(_ path: String) {
        pendingWebPath = path
        selectedTab = .web
    }

    func consumePendingWebPath() -> String? {
        defer { pendingWebPath = nil }
        return pendingWebPath
    }

    // MARK: - 登录

    func login(username: String, password: String) async {
        errorText = nil
        do {
            let result = try await api.login(username: username, password: password)
            token = result.token
            refreshToken = result.refreshToken
            self.username = result.username ?? username
            AppSettings.token = result.token
            AppSettings.refreshToken = result.refreshToken
            AppSettings.username = self.username
            await loadAccounts()
            if selectedAccount == nil { selectedAccount = accounts.first }
            await reloadAll()
        } catch {
            handle(error)
        }
    }

    func logout() {
        token = nil
        refreshToken = nil
        username = nil
        selectedAccount = nil
        accounts = []
        conversations = []
        messages = []
        quickPhrases = []
        AppSettings.clearLogin()
    }

    func setServer(_ raw: String) async {
        guard let url = URL(string: raw) else {
            errorText = "地址格式不对，例如 http://192.168.1.10:9000"
            return
        }
        AppSettings.serverURL = url
        api.baseURL = url
    }

    /// 进入主界面时的一次性准备：拉账号 → 选第一个 → 拉会话（已有数据就不重复拉）
    func ensureReady() async {
        if accounts.isEmpty { await loadAccounts() }
        if selectedAccount == nil { selectedAccount = accounts.first }
        if conversations.isEmpty { await reloadConversations() }
    }

    /// 未读总数（角标用）
    var totalUnread: Int {
        conversations.reduce(0) { $0 + max(0, $1.unreadCount) }
    }

    // MARK: - 实时推送（WebSocket）

    private static var wsClient: ChatWebSocketClient?

    /// 建立实时通道（切账号 / 回前台时调用）
    func startRealtime() {
        guard let account = selectedAccount, let token, !token.isEmpty else { return }
        let client = AppState.wsClient ?? {
            let c = ChatWebSocketClient()
            AppState.wsClient = c
            return c
        }()
        client.onEvent = { [weak self] event in
            guard let self else { return }
            if Thread.isMainThread { self.handleRealtime(event) }
            else { DispatchQueue.main.async { self.handleRealtime(event) } }
        }
        client.connect(serverURL: AppSettings.serverURL, accountId: account.accountId, token: token)
        startFallbackTimer()
    }

    func stopRealtime() {
        AppState.wsClient?.disconnect(byUser: true)
        realtimeConnected = false
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    /// 兜底轮询：只有实时通道断开时才跑，60 秒一次（1.3.0 的 20 秒轮询会把闲鱼接口压垮）
    private var fallbackTimer: Timer?
    private func startFallbackTimer() {
        guard fallbackTimer == nil else { return }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.realtimeConnected else { return }
                await self.silentRefresh()
            }
        }
    }

    private func handleRealtime(_ event: ChatWebSocketClient.Event) {
        switch event {
        case .connected:
            realtimeConnected = true
            Task { await silentRefresh() }      // 补上断线期间可能漏掉的消息
        case .disconnected:
            realtimeConnected = false
        case .newMessage(let cid, let msg):
            applyIncoming(cid: cid, message: msg)
        }
    }

    /// 收到一条推送：更新会话列表 / 当前聊天 / 未读 / 通知
    private func applyIncoming(cid: String, message msg: ChatMessage) {
        let summary = msg.type == "image" ? "[图片]" : String(msg.text.prefix(60))
        let accountId = selectedAccount?.accountId ?? ""
        let viewing = (viewingCID == cid)

        if let idx = conversations.firstIndex(where: { $0.cid == cid }) {
            conversations[idx].lastMessageSummary = summary.isEmpty ? "新消息" : summary
            conversations[idx].lastMessageTime = msg.time
            if !msg.isSelf && !viewing {
                conversations[idx].unreadCount += 1
            }
            // 有新消息的会话排到最前
            let conv = conversations.remove(at: idx)
            conversations.insert(conv, at: 0)
        }

        if viewing {
            if !messages.contains(where: { $0.messageId == msg.messageId }) {
                messages.append(msg)
            }
            if !msg.isSelf, let conv = conversations.first(where: { $0.cid == cid }) {
                markRead(conv, latestMessageTime: msg.time)
            }
        } else if !msg.isSelf {
            NotificationManager.shared.handleConversations(conversations,
                                                           accountName: selectedAccount?.displayName ?? "")
            NotificationManager.shared.updateBadge(totalUnread)
        }
        _ = accountId
    }

    // MARK: - 数据加载

    /// 静默刷新：不转菊花、不弹红条，只为了让通知/角标拿到最新未读
    func silentRefresh() async {
        guard let account = selectedAccount else { return }
        do {
            let page = try await api.conversations(accountId: account.accountId, cursor: nil)
            // 按本地已读水位清零，否则"点过又刷新"红点会复现
            conversations = ReadStore.apply(account: account.accountId, conversations: page.conversations)
            convCursor = page.nextCursor
            NotificationManager.shared.handleConversations(conversations,
                                                           accountName: account.displayName)
            await refreshOrderTags()
            startTagTimer()
        } catch {
            // 后台刷新失败就算了，不打扰用户
        }
    }

    /// 后台任务入口（App 被系统唤醒时）
    func refreshInBackground() async {
        api.baseURL = AppSettings.serverURL
        api.token = AppSettings.token
        if accounts.isEmpty {
            await loadAccounts()
        }
        if selectedAccount == nil { selectedAccount = accounts.first }
        await silentRefresh()
    }

    func loadAccounts() async {
        loadingAccounts = true
        defer { loadingAccounts = false }
        do {
            accounts = try await api.accounts()
        } catch {
            handle(error)
        }
    }

    func select(account: ChatAccount) async {
        selectedAccount = account
        await reloadConversations()
    }

    func reloadAll() async {
        await reloadConversations()
        await loadQuickPhrases()
    }

    func reloadConversations() async {
        guard let account = selectedAccount else { return }
        loadingConversations = true
        convCursor = nil
        defer { loadingConversations = false }
        do {
            let page = try await api.conversations(accountId: account.accountId, cursor: nil)
            conversations = page.conversations
            convCursor = page.nextCursor
            NotificationManager.shared.handleConversations(conversations,
                                                           accountName: account.displayName)
        } catch {
            handle(error)
        }
    }

    func loadMoreConversations() async {
        guard let account = selectedAccount, let cursor = convCursor else { return }
        do {
            let page = try await api.conversations(accountId: account.accountId, cursor: cursor)
            conversations += ReadStore.apply(account: account.accountId, conversations: page.conversations)
            convCursor = page.nextCursor
        } catch {
            handle(error)
        }
    }

    func loadMessages(conversation: Conversation, reset: Bool = true) async {
        guard let account = selectedAccount else { return }
        if reset {
            loadingMessages = true
            msgCid = conversation.cid
            msgCursor = nil
            messages = []
        }
        defer { loadingMessages = false }
        do {
            let page = try await api.messages(accountId: account.accountId,
                                              cid: conversation.cid,
                                              cursor: reset ? nil : msgCursor)
            if reset {
                messages = page.messages
            } else {
                messages = page.messages + messages
            }
            msgCursor = page.nextCursor
        } catch {
            handle(error)
        }
    }

    func loadOlderMessages(conversation: Conversation) async {
        guard msgCursor != nil else { return }
        await loadMessages(conversation: conversation, reset: false)
    }

    func send(text: String, to conversation: Conversation) async {
        guard let account = selectedAccount, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        defer { sending = false }
        // 乐观插入，失败再标红（对齐网页端体验）
        let local = ChatMessage.placeholder(text: text)
        messages.append(local)
        do {
            try await api.sendMessage(accountId: account.accountId,
                                      cid: conversation.cid,
                                      toUserId: conversation.otherUserId,
                                      text: text)
        } catch {
            messages.removeAll { $0.messageId == local.messageId }
            handle(error)
        }
    }

    func loadQuickPhrasesIfNeeded() async {
        guard quickPhrases.isEmpty else { return }
        await loadQuickPhrases()
    }

    func loadQuickPhrases() async {
        do {
            quickPhrases = try await api.quickPhrases()
        } catch {
            // 快捷短语失败不打扰用户
        }
    }
}

extension ChatMessage {
    /// 本地乐观插入的消息（发送成功后由下次刷新替换成服务端数据）
    static func placeholder(text: String) -> ChatMessage {
        ChatMessage(messageId: "local-\(UUID().uuidString)",
                    senderName: "我",
                    isSelf: true,
                    type: "text",
                    text: text,
                    time: Date().timeIntervalSince1970 * 1000)
    }
}
