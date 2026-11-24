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
    /// 消息页是否把所有账号的会话聚合在一起（默认开启，对齐网页版"全部账号"）
    @Published var allAccountsMode = true
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
    /// 深链查询参数（中文等由 URLComponents 统一编码，避免手写百分号出错）
    @Published var pendingWebQuery: [String: String] = [:]
    /// 实时通道是否在线（WebSocket 连上 = true）
    @Published var realtimeConnected = false
    /// 当前正在看的会话（收到推送时判断要不要追加到聊天窗口）
    @Published var viewingCID: String?
    /// 正在看的会话属于哪个账号（聚合模式下同一 cid 可能存在于多个账号）
    @Published var viewingAccountId: String?
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
        let aid = accountId(for: conversation)
        guard !aid.isEmpty else { return }
        let time = max(conversation.lastMessageTime, latestMessageTime ?? 0)
        ReadStore.mark(account: aid, cid: conversation.cid,
                       time: time, summary: conversation.lastMessageSummary)
        if let idx = conversations.firstIndex(where: { $0.cid == conversation.cid && $0.accountId == aid }),
           conversations[idx].unreadCount > 0 {
            conversations[idx].unreadCount = 0
            NotificationManager.shared.updateBadge(totalUnread)
        }
    }

    /// 会话所属账号（聚合模式下以会话自带 accountId 为准）
    func accountId(for conversation: Conversation) -> String {
        conversation.accountId.isEmpty ? (selectedAccount?.accountId ?? "") : conversation.accountId
    }

    private func accountName(for accountId: String) -> String {
        accounts.first(where: { $0.accountId == accountId })?.displayName ?? accountId
    }

    /// 渲染层判断：这个会话是否已读（不依赖刷新流程是否执行过 apply）
    func isRead(_ conversation: Conversation) -> Bool {
        let aid = accountId(for: conversation)
        guard !aid.isEmpty else { return false }
        return ReadStore.isRead(account: aid, cid: conversation.cid,
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
    func openInWeb(_ path: String, query: [String: String] = [:]) {
        pendingWebQuery = query
        pendingWebPath = path
        selectedTab = .web
    }

    func consumePendingWebPath() -> String? {
        defer {
            pendingWebPath = nil
            pendingWebQuery = [:]
        }
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

    /// 每个账号一条 WS（聚合模式下要同时收所有账号的消息）
    private var wsClients: [String: ChatWebSocketClient] = [:]

    /// 建立实时通道：为所有启用账号各连一条（对齐网页版"全部账号"）
    func startRealtime() {
        guard let token, !token.isEmpty else { return }
        var targets = accounts.filter { $0.status == "active" }.map(\.accountId)
        if targets.isEmpty, let only = selectedAccount?.accountId { targets = [only] }
        guard !targets.isEmpty else { return }

        lastConnectAttempt = Date()
        for aid in targets {
            if let existing = wsClients[aid], existing.isConnected { continue }
            let client = wsClients[aid] ?? {
                let c = ChatWebSocketClient()
                wsClients[aid] = c
                return c
            }()
            client.onEvent = { [weak self] event in
                guard let self else { return }
                if Thread.isMainThread { self.handleRealtime(event, accountId: aid) }
                else { DispatchQueue.main.async { self.handleRealtime(event, accountId: aid) } }
            }
            client.connect(serverURL: AppSettings.serverURL, accountId: aid, token: token)
        }
        startFallbackTimer()
    }

    /// 上一次发起 WS 连接的时间（用于识别"刚连上就被踢"= 鉴权失败）
    private var lastConnectAttempt = Date.distantPast
    private var lastAuthRetryAt = Date.distantPast

    /// access token 只有 30 分钟：WS 连接不走 APIClient 的 401 重试，
    /// 拿过期 token 会被后端以 4401 关掉 → 表现为"一直重连但收不到消息"（2026-11-23 实锤）。
    /// 这里在识别到"刚连上就断"时刷新令牌并立即重连，30 秒内只做一次。
    private func refreshTokenAndReconnect() async {
        guard Date().timeIntervalSince(lastAuthRetryAt) > 30 else { return }
        lastAuthRetryAt = Date()
        if await api.refreshAccessToken() {
            token = api.token
            AppSettings.token = api.token
        }
        lastConnectAttempt = Date()
        let ids = wsClients.keys.isEmpty
            ? (selectedAccount.map { [$0.accountId] } ?? [])
            : Array(wsClients.keys)
        let tokenValue = token ?? ""
        await MainActor.run {
            for aid in ids {
                wsClients[aid]?.connect(serverURL: AppSettings.serverURL, accountId: aid, token: tokenValue)
            }
        }
    }

    func stopRealtime() {
        wsClients.values.forEach { $0.disconnect(byUser: true) }
        wsClients.removeAll()
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

    private func handleRealtime(_ event: ChatWebSocketClient.Event, accountId: String) {
        switch event {
        case .connected:
            realtimeConnected = true
            Task { await silentRefresh() }      // 补上断线期间可能漏掉的消息
        case .disconnected:
            realtimeConnected = false
            // 连上不到 3 秒就断 → 大概率是 token 过期被 4401 拒绝，刷新后重连
            if Date().timeIntervalSince(lastConnectAttempt) < 3 {
                Task { await refreshTokenAndReconnect() }
            }
        case .newMessage(let cid, let msg):
            applyIncoming(cid: cid, message: msg, accountId: accountId)
        }
    }

    /// 占位会话补全（去抖：3 秒内最多一次）
    private var lastCorrectionAt = Date.distantPast
    private func scheduleListCorrection() {
        guard Date().timeIntervalSince(lastCorrectionAt) > 3 else { return }
        lastCorrectionAt = Date()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.silentRefresh()
        }
    }

    /// 收到一条推送：更新会话列表 / 当前聊天 / 未读 / 通知
    private func applyIncoming(cid: String, message msg: ChatMessage, accountId: String) {
        let summary = msg.type == "image" ? "[图片]" : String(msg.text.prefix(60))
        let viewing = (viewingCID == cid && (viewingAccountId == nil || viewingAccountId == accountId))

        if let idx = conversations.firstIndex(where: { $0.cid == cid && $0.accountId == accountId }) {
            conversations[idx].lastMessageSummary = summary.isEmpty ? "新消息" : summary
            conversations[idx].lastMessageTime = msg.time
            if !msg.isSelf && !viewing {
                conversations[idx].unreadCount += 1
            }
            // 有新消息的会话排到最前
            let conv = conversations.remove(at: idx)
            conversations.insert(conv, at: 0)
        } else if !msg.isSelf {
            // 列表里还没有这个会话（新买家第一条消息）——**必须插进去**，
            // 否则推送到了也只更新不到任何行，表现为"消息不同步"（2026-11-23 实锤）。
            var placeholder = Conversation(
                cid: cid,
                otherUserId: msg.senderId,
                otherUserName: msg.senderName.isEmpty ? "新买家" : msg.senderName,
                lastMessageSummary: summary.isEmpty ? "新消息" : summary,
                lastMessageTime: msg.time,
                unreadCount: viewing ? 0 : 1
            )
            placeholder.accountId = accountId
            placeholder.accountName = accountName(for: accountId)
            conversations.insert(placeholder, at: 0)
            // 占位信息不全（头像/商品），1.5 秒后补拉一次真实列表校正；3 秒内只跑一次
            scheduleListCorrection()
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
        loadingConversations = true
        convCursor = nil
        defer { loadingConversations = false }

        if allAccountsMode {
            // 聚合：并发拉所有启用账号的首屏会话，按时间合并（对齐网页版"全部账号"）
            // 账号去重：后端可能因"同一店铺多个 Cookie"返回重复 account_id，
            // 重复拉取会让 merged 里出现同 (accountId,cid) 的两条 → SwiftUI 列表 diff 时
            // id 重复直接崩（2026-11-24 用户反馈"点刷新闪退"）。这里先按 accountId 去重。
            var seenAccounts = Set<String>()
            let targets = accounts.filter {
                $0.status == "active" && seenAccounts.insert($0.accountId).inserted
            }
            guard !targets.isEmpty else { return }
            // ⚠️ 这里必须**串行**拉取：APIClient 是 class，token/baseURL 是可变属性，
            // 用 withTaskGroup 并发调用同一个实例 = 多线程读写同一份可变状态（ARC 引用计数竞态），
            // 会偶发 EXC_BAD_ACCESS 闪退（2026-11-24 用户"刷新就崩"）。
            // 5 个账号串行拉一遍约 1~2 秒，换来的是绝对安全。
            var merged: [Conversation] = []
            for acc in targets {
                do {
                    let page = try await api.conversations(accountId: acc.accountId, cursor: nil)
                    for var c in page.conversations {
                        c.accountId = acc.accountId
                        c.accountName = acc.displayName
                        merged.append(c)
                    }
                } catch {
                    continue    // 单个账号失败不影响其它账号
                }
            }
            // 再按 (accountId, cid) 去重：同一会话只保留最后消息时间最新的那条
            var unique: [String: Conversation] = [:]
            for c in merged {
                let key = "\(c.accountId)|\(c.cid)"
                if let exist = unique[key], exist.lastMessageTime >= c.lastMessageTime { continue }
                unique[key] = c
            }
            merged = Array(unique.values)
            merged.sort { $0.lastMessageTime > $1.lastMessageTime }
            // 按账号分组套用本地已读水位
            var out: [Conversation] = []
            for group in Dictionary(grouping: merged, by: { $0.accountId }) {
                out += ReadStore.apply(account: group.key, conversations: group.value)
            }
            conversations = out.sorted { $0.lastMessageTime > $1.lastMessageTime }
            NotificationManager.shared.handleConversations(conversations,
                                                           accountName: "全部账号")
            await refreshOrderTags()
            startTagTimer()
            return
        }

        guard let account = selectedAccount else { return }
        do {
            let page = try await api.conversations(accountId: account.accountId, cursor: nil)
            conversations = ReadStore.apply(account: account.accountId, conversations: page.conversations)
            convCursor = page.nextCursor
            NotificationManager.shared.handleConversations(conversations,
                                                           accountName: account.displayName)
        } catch {
            handle(error)
        }
    }

    func loadMoreConversations() async {
        guard !allAccountsMode, let account = selectedAccount, let cursor = convCursor else { return }
        do {
            let page = try await api.conversations(accountId: account.accountId, cursor: cursor)
            conversations += ReadStore.apply(account: account.accountId, conversations: page.conversations)
            convCursor = page.nextCursor
        } catch {
            handle(error)
        }
    }

    func loadMessages(conversation: Conversation, reset: Bool = true) async {
        let accountIdValue = accountId(for: conversation)
        guard !accountIdValue.isEmpty else { return }
        if reset {
            loadingMessages = true
            msgCid = conversation.cid
            msgCursor = nil
            messages = []
        }
        defer { loadingMessages = false }
        do {
            let page = try await api.messages(accountId: accountIdValue,
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
        let aid = accountId(for: conversation)
        guard !aid.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        defer { sending = false }
        // 乐观插入，失败再标红（对齐网页端体验）
        let local = ChatMessage.placeholder(text: text)
        messages.append(local)
        do {
            try await api.sendMessage(accountId: aid,
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
