import Foundation

/// 已读水位（本地）
///
/// 为什么需要：后端没有"标记已读"接口（网页端也是本地水位），
/// 不记水位的话每次刷新都会把后端返回的未读数重新显示成红点。
///
/// ⚠️ 存储用 JSON(Data) 而不是 `UserDefaults.dictionary(forKey:)`：
/// 后者返回 `[String: Any]`，值是 NSNumber，`as? [String: Double]` 的桥接行为
/// 在真机上并不可靠 —— 一旦读回失败就变成"水位永远为空"，红点刷新后又出现
/// （2026-11-23 用户反馈"气泡还是没解决"）。JSON 编解码没有这个歧义。
enum ReadStore {
    private static let key = "xy.readMarks.v2"
    private static let legacyKey = "xy.readMarks"
    private static let lock = NSLock()
    /// 缓存，避免每次列表刷新都读一次磁盘
    private static var cache: [String: Double]?

    private static func load() -> [String: Double] {
        if let cache { return cache }
        var map: [String: Double] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            map = decoded
        } else if let legacy = UserDefaults.standard.dictionary(forKey: legacyKey) {
            // 兼容旧版本写入的 NSNumber 字典
            for (k, v) in legacy {
                if let d = v as? Double { map[k] = d }
                else if let n = v as? NSNumber { map[k] = n.doubleValue }
            }
        }
        cache = map
        return map
    }

    private static func save(_ map: [String: Double]) {
        cache = map
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func id(account: String, cid: String) -> String { "\(account)|\(cid)" }

    /// 记录"读到哪条消息"（时间戳毫秒）
    static func mark(account: String, cid: String, time: Double) {
        guard time > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var map = load()
        let k = id(account: account, cid: cid)
        if time > (map[k] ?? 0) { map[k] = time; save(map) }
    }

    /// 一键已读
    static func markAll(account: String, conversations: [Conversation]) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        var changed = false
        for c in conversations {
            let k = id(account: account, cid: c.cid)
            if c.lastMessageTime > (map[k] ?? 0) { map[k] = c.lastMessageTime; changed = true }
        }
        if changed { save(map) }
    }

    /// 按水位把未读清零
    static func apply(account: String, conversations: [Conversation]) -> [Conversation] {
        lock.lock(); defer { lock.unlock() }
        let map = load()
        guard !map.isEmpty else { return conversations }
        return conversations.map { c in
            guard c.unreadCount > 0 else { return c }
            let mark = map[id(account: account, cid: c.cid)] ?? 0
            guard mark > 0, mark >= c.lastMessageTime else { return c }
            var copy = c
            copy.unreadCount = 0
            return copy
        }
    }

    /// 诊断用：已记录多少条会话
    static func count() -> Int { load().count }

    static func clearAll() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}
