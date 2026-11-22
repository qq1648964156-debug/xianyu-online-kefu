import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
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

    private var convCursor: Int?
    private var msgCursor: Int?
    private var msgCid: String?
    private let api = APIClient.shared

    var isLoggedIn: Bool { token?.isEmpty == false }

    init() {
        api.baseURL = AppSettings.serverURL
        api.token = AppSettings.token
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
            errorText = (error as? APIError)?.message ?? error.localizedDescription
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

    // MARK: - 数据加载

    func loadAccounts() async {
        loadingAccounts = true
        defer { loadingAccounts = false }
        do {
            accounts = try await api.accounts()
        } catch {
            errorText = (error as? APIError)?.message ?? error.localizedDescription
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
        } catch {
            errorText = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    func loadMoreConversations() async {
        guard let account = selectedAccount, let cursor = convCursor else { return }
        do {
            let page = try await api.conversations(accountId: account.accountId, cursor: cursor)
            conversations += page.conversations
            convCursor = page.nextCursor
        } catch {
            errorText = (error as? APIError)?.message ?? error.localizedDescription
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
            errorText = (error as? APIError)?.message ?? error.localizedDescription
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
            errorText = (error as? APIError)?.message ?? error.localizedDescription
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
