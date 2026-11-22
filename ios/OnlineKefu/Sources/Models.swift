import Foundation

// MARK: - 接口返回包装

/// 后端统一返回 `{ success, message, data }`；`data` 可能是对象也可能是数组。
struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let message: String?
    let data: T?
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 登录

struct LoginResult: Decodable {
    let token: String
    let refreshToken: String?
    let userId: Int?
    let username: String?
    let isAdmin: Bool?

    enum CodingKeys: String, CodingKey {
        case token
        case refreshToken = "refresh_token"
        case userId = "user_id"
        case username
        case isAdmin = "is_admin"
    }
}

struct LoginResponse: Decodable {
    let success: Bool?
    let message: String?
    let token: String?
    let refreshToken: String?
    let userId: Int?
    let username: String?
    let isAdmin: Bool?

    var result: LoginResult? {
        guard let token else { return nil }
        return LoginResult(token: token, refreshToken: refreshToken, userId: userId,
                           username: username, isAdmin: isAdmin)
    }

    enum CodingKeys: String, CodingKey {
        case success, message, token, username
        case refreshToken = "refresh_token"
        case userId = "user_id"
        case isAdmin = "is_admin"
    }
}

// MARK: - 账号 / 会话 / 消息

struct ChatAccount: Decodable, Identifiable, Hashable {
    let accountId: String
    let displayName: String
    let remark: String
    let connected: Bool
    let status: String
    let owner: String?

    var id: String { accountId }
    var title: String {
        let name = displayName.isEmpty ? accountId : displayName
        return remark.isEmpty ? name : "\(remark)（\(name)）"
    }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case displayName = "display_name"
        case remark, connected, status, owner
    }
}

/// /chat-new/accounts 的原始返回：列表在 data 里，total / hasMore 在顶层
struct AccountsResponse: Decodable {
    let success: Bool?
    let message: String?
    let data: [ChatAccount]?
    let total: Int?
    let hasMore: Bool?
}

struct Conversation: Decodable, Identifiable, Hashable {
    let cid: String
    let rawCid: String?
    let otherUserId: String
    let otherUserName: String
    let otherUserAvatar: String
    let itemTitle: String
    let itemId: String?
    let lastMessageSummary: String
    let lastMessageTime: Double
    var unreadCount: Int

    var id: String { cid }

    enum CodingKeys: String, CodingKey {
        case cid, rawCid, otherUserId, otherUserName, otherUserAvatar
        case itemTitle, itemId, lastMessageSummary, lastMessageTime, unreadCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cid = (try? c.decode(String.self, forKey: .cid)) ?? ""
        rawCid = try? c.decodeIfPresent(String.self, forKey: .rawCid)
        otherUserId = (try? c.decode(String.self, forKey: .otherUserId)) ?? ""
        otherUserName = (try? c.decode(String.self, forKey: .otherUserName)) ?? ""
        otherUserAvatar = (try? c.decode(String.self, forKey: .otherUserAvatar)) ?? ""
        itemTitle = (try? c.decode(String.self, forKey: .itemTitle)) ?? ""
        itemId = try? c.decodeIfPresent(String.self, forKey: .itemId)
        lastMessageSummary = (try? c.decode(String.self, forKey: .lastMessageSummary)) ?? ""
        lastMessageTime = (try? c.decode(Double.self, forKey: .lastMessageTime)) ?? 0
        unreadCount = (try? c.decode(Int.self, forKey: .unreadCount)) ?? 0
    }
}

struct ConversationPage: Decodable {
    let conversations: [Conversation]
    let hasMore: Bool
    let nextCursor: Int?

    enum CodingKeys: String, CodingKey { case conversations, hasMore, nextCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = (try? c.decode([Conversation].self, forKey: .conversations)) ?? []
        hasMore = (try? c.decode(Bool.self, forKey: .hasMore)) ?? false
        nextCursor = try? c.decodeIfPresent(Int.self, forKey: .nextCursor)
    }
}

struct ChatMessage: Decodable, Identifiable {
    let messageId: String
    let senderName: String
    let isSelf: Bool
    let type: String
    let text: String
    let images: [String]
    let time: Double

    var id: String { messageId }
    var isImage: Bool { type == "image" && !images.isEmpty }

    enum CodingKeys: String, CodingKey {
        case messageId, senderName, isSelf, type, text, images, time
    }

    init(messageId: String, senderName: String, isSelf: Bool, type: String,
         text: String, images: [String] = [], time: Double) {
        self.messageId = messageId
        self.senderName = senderName
        self.isSelf = isSelf
        self.type = type
        self.text = text
        self.images = images
        self.time = time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = (try? c.decode(String.self, forKey: .messageId)) ?? UUID().uuidString
        senderName = (try? c.decode(String.self, forKey: .senderName)) ?? ""
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
        type = (try? c.decode(String.self, forKey: .type)) ?? "text"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        images = (try? c.decode([String].self, forKey: .images)) ?? []
        time = (try? c.decode(Double.self, forKey: .time)) ?? 0
    }
}

struct MessagePage: Decodable {
    let messages: [ChatMessage]
    let hasMore: Bool
    let nextCursor: Int?

    enum CodingKeys: String, CodingKey { case messages, hasMore, nextCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try? c.decode([ChatMessage].self, forKey: .messages)) ?? []
        hasMore = (try? c.decode(Bool.self, forKey: .hasMore)) ?? false
        nextCursor = try? c.decodeIfPresent(Int.self, forKey: .nextCursor)
    }
}

struct QuickPhrase: Decodable, Identifiable {
    let id: Int
    let title: String
    let content: String
}
