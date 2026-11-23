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
    var lastMessageSummary: String
    var lastMessageTime: Double
    var unreadCount: Int

    var id: String { cid }

    enum CodingKeys: String, CodingKey {
        case cid, rawCid, otherUserId, otherUserName, otherUserAvatar
        case itemTitle, itemId, lastMessageSummary, lastMessageTime, unreadCount
    }

    /// 推送新建会话时用（后端列表里还没有这个会话）
    init(cid: String, rawCid: String? = nil, otherUserId: String, otherUserName: String,
         otherUserAvatar: String = "", itemTitle: String = "", itemId: String? = nil,
         lastMessageSummary: String, lastMessageTime: Double, unreadCount: Int) {
        self.cid = cid
        self.rawCid = rawCid
        self.otherUserId = otherUserId
        self.otherUserName = otherUserName
        self.otherUserAvatar = otherUserAvatar
        self.itemTitle = itemTitle
        self.itemId = itemId
        self.lastMessageSummary = lastMessageSummary
        self.lastMessageTime = lastMessageTime
        self.unreadCount = unreadCount
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
    /// 发送者ID（推送里带，用于新会话占位时定位买家）
    let senderId: String
    let isSelf: Bool
    let type: String
    let text: String
    let images: [String]
    let time: Double

    var id: String { messageId }
    var isImage: Bool { type == "image" && !images.isEmpty }

    enum CodingKeys: String, CodingKey {
        case messageId, senderName, senderId, isSelf, type, text, images, time
    }

    init(messageId: String, senderName: String, isSelf: Bool, type: String,
         text: String, images: [String] = [], time: Double, senderId: String = "") {
        self.messageId = messageId
        self.senderName = senderName
        self.senderId = senderId
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
        senderId = (try? c.decode(String.self, forKey: .senderId)) ?? ""
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


// MARK: - 买家订单 / 咨询商品（聊天页「会话信息」用）

struct CustomerOrder: Decodable, Identifiable {
    let orderNo: String
    let itemTitle: String
    let skuInfo: String
    let amount: String
    let status: String
    let quantity: Int
    let placedAt: String
    let deliveryMethod: String
    let refundStatusDesc: String?

    var id: String { orderNo }
    var statusText: String {
        if let r = refundStatusDesc, !r.isEmpty { return "\(status) · \(r)" }
        return status
    }

    enum CodingKeys: String, CodingKey {
        case orderNo = "order_no"
        case itemTitle = "item_title"
        case skuInfo = "sku_info"
        case amount, status, quantity
        case placedAt = "placed_at"
        case deliveryMethod = "delivery_method"
        case refundStatusDesc = "refund_status_desc"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderNo = (try? c.decode(String.self, forKey: .orderNo)) ?? ""
        itemTitle = (try? c.decode(String.self, forKey: .itemTitle)) ?? ""
        skuInfo = (try? c.decode(String.self, forKey: .skuInfo)) ?? ""
        amount = (try? c.decode(String.self, forKey: .amount)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        quantity = (try? c.decode(Int.self, forKey: .quantity)) ?? 0
        placedAt = (try? c.decode(String.self, forKey: .placedAt)) ?? ""
        deliveryMethod = (try? c.decode(String.self, forKey: .deliveryMethod)) ?? ""
        refundStatusDesc = try? c.decodeIfPresent(String.self, forKey: .refundStatusDesc)
    }
}

struct ConsultSku: Decodable, Identifiable {
    let skuId: String
    let name: String
    let price: String
    let stock: String?

    var id: String { skuId.isEmpty ? name : skuId }

    enum CodingKeys: String, CodingKey { case skuId, name, price, stock }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skuId = (try? c.decode(String.self, forKey: .skuId)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        price = (try? c.decode(String.self, forKey: .price)) ?? ""
        stock = try? c.decodeIfPresent(String.self, forKey: .stock)
    }
}

struct ConsultItem: Decodable {
    let itemId: String
    let title: String
    let image: String
    let price: String
    let specLines: [String]
    let skus: [ConsultSku]
    let quantity: String?

    enum CodingKeys: String, CodingKey {
        case itemId, title, image, price, specLines, skus, quantity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = (try? c.decode(String.self, forKey: .itemId)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        image = (try? c.decode(String.self, forKey: .image)) ?? ""
        price = (try? c.decode(String.self, forKey: .price)) ?? ""
        specLines = (try? c.decode([String].self, forKey: .specLines)) ?? []
        skus = (try? c.decode([ConsultSku].self, forKey: .skus)) ?? []
        quantity = try? c.decodeIfPresent(String.self, forKey: .quantity)
    }
}


// MARK: - 会话订单状态标签（后端只读本地库，不触发闲鱼接口）

struct ConversationOrderTag: Decodable {
    let accountId: String
    let buyerId: String
    let chatId: String
    let status: String
    let orderNo: String
    let placedAt: String
    let orderCount: Int

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case buyerId = "buyer_id"
        case chatId = "chat_id"
        case status
        case orderNo = "order_no"
        case placedAt = "placed_at"
        case orderCount = "order_count"
    }

    /// 会话列表里的中文文案（对齐网页端）
    var chatLabel: String {
        switch status {
        case "refunding": return "买家申请退款"
        case "refunded": return "已退款"
        case "pending_payment": return "待付款"
        case "pending_ship", "pending", "paid": return "待发货"
        case "shipped": return "已发货"
        case "completed": return "交易成功"
        case "cancelled": return "交易关闭"
        default: return status
        }
    }
}
