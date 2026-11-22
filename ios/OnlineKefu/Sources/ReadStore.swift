import Foundation

/// 已读水位（本地）
///
/// 为什么需要：后端没有"标记已读"接口（网页端也是纯本地水位）。
/// 原先 App 只在内存里把 unreadCount 置 0，**一刷新又从后端拿回旧值，红点复现**——
/// 这就是"点一下气泡消失、刷新后又回来"的原因（2026-11-22 用户反馈）。
/// 这里把「账号+cid → 已读到的最后一条消息时间」持久化，每次拉列表都按水位清零。
enum ReadStore {
    private static let key = "xy.readMarks"
    private static let lock = NSLock()

    private static func load() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
    }

    private static func save(_ map: [String: Double]) {
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func id(account: String, cid: String) -> String { "\(account)|\(cid)" }

    static func mark(account: String, cid: String, time: Double) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        let k = id(account: account, cid: cid)
        if time > (map[k] ?? 0) { map[k] = time }
        save(map)
    }

    /// 一键已读：把当前列表里所有会话都按最新消息时间打水位
    static func markAll(account: String, conversations: [Conversation]) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        for c in conversations {
            let k = id(account: account, cid: c.cid)
            if c.lastMessageTime > (map[k] ?? 0) { map[k] = c.lastMessageTime }
        }
        save(map)
    }

    /// 按水位把未读清零（水位 >= 该会话最后消息时间 → 视为已读）
    static func apply(account: String, conversations: [Conversation]) -> [Conversation] {
        lock.lock(); defer { lock.unlock() }
        let map = load()
        return conversations.map { c in
            var copy = c
            if copy.unreadCount > 0 {
                let mark = map[id(account: account, cid: c.cid)] ?? 0
                if mark >= copy.lastMessageTime { copy.unreadCount = 0 }
            }
            return copy
        }
    }
}
