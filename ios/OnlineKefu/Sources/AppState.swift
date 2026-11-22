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
        ReadStore.mark(account: account.accountId, cid: conversation.cid, time: time)
        if let idx = conversations.firstIndex(where: { $0.cid == conversation.cid }),
           conversations[idx].unreadCount > 0 {
            conversations[idx].unreadCount = 0
            NotificationManager.shared.updateBadge(totalUnread)
        }
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
