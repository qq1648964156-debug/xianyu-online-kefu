import Foundation

/// 已读水位（本地）
///
/// 后端没有"标记已读"接口（网页端也是本地水位），所以必须由客户端记住：
/// 「这个会话我已经读到哪儿了」，否则每次刷新都会把后端返回的未读数重新画成红点。
///
/// v3 起记录 **时间戳 + 最后一条消息摘要** 两个维度：
///   - 时间戳做兜底（容忍 60 秒漂移，避免后端时间戳刷新时微调导致判断失效）；
///   - 摘要相同 ⇒ 没有新的买家消息 ⇒ 一定算已读（这是最强判据）。
enum ReadStore {
    struct Mark: Codable {
        var time: Double
        var summary: String
    }

    private static let key = "xy.readMarks.v3"
    private static let legacyKeys = ["xy.readMarks.v2", "xy.readMarks"]
    private static let lock = NSLock()
    private static var cache: [String: Mark]?

    private static func load() -> [String: Mark] {
        if let cache { return cache }
        var map: [String: Mark] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Mark].self, from: data) {
            map = decoded
        } else {
            // 兼容 v2（[String: Double]）与 v1（NSNumber 字典）
            if let data = UserDefaults.standard.data(forKey: "xy.readMarks.v2"),
               let old = try? JSONDecoder().decode([String: Double].self, from: data) {
                for (k, v) in old { map[k] = Mark(time: v, summary: "") }
            } else if let old = UserDefaults.standard.dictionary(forKey: "xy.readMarks") {
                for (k, v) in old {
                    if let n = v as? NSNumber { map[k] = Mark(time: n.doubleValue, summary: "") }
                }
            }
        }
        cache = map
        return map
    }

    private static func save(_ map: [String: Mark]) {
        cache = map
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func id(_ account: String, _ cid: String) -> String { "\(account)|\(cid)" }

    static func mark(account: String, cid: String, time: Double, summary: String) {
        guard time > 0 || !summary.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var map = load()
        let k = id(account, cid)
        let old = map[k]
        // 只在"更靠后"时更新，避免把已读进度覆盖回旧值
        if old == nil || time >= old!.time || (!summary.isEmpty && summary != old!.summary) {
            map[k] = Mark(time: max(time, old?.time ?? 0), summary: summary)
            save(map)
        }
    }

    static func markAll(account: String, conversations: [Conversation]) {
        lock.lock(); defer { lock.unlock() }
        var map = load(); var changed = false
        for c in conversations {
            let k = id(account, c.cid)
            if map[k] == nil || c.lastMessageTime >= (map[k]?.time ?? 0) {
                map[k] = Mark(time: c.lastMessageTime, summary: c.lastMessageSummary)
                changed = true
            }
        }
        if changed { save(map) }
    }

    /// 这个会话是否已读（**渲染层与刷新层都调用它**，双保险）
    static func isRead(account: String, cid: String, time: Double, summary: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let m = load()[id(account, cid)] else { return false }
        if !m.summary.isEmpty, m.summary == summary { return true }        // 摘要没变 = 没新消息
        return time <= m.time + 60_000                                    // 容忍 60s 时间戳漂移
    }

    static func apply(account: String, conversations: [Conversation]) -> [Conversation] {
        conversations.map { c in
            guard c.unreadCount > 0 else { return c }
            guard isRead(account: account, cid: c.cid,
                         time: c.lastMessageTime, summary: c.lastMessageSummary) else { return c }
            var copy = c
            copy.unreadCount = 0
            return copy
        }
    }

    static func count() -> Int { load().count }

    static func clearAll() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        UserDefaults.standard.removeObject(forKey: key)
        for k in legacyKeys { UserDefaults.standard.removeObject(forKey: k) }
    }
}
