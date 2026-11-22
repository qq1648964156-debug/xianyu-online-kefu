import SwiftUI
import UserNotifications
import BackgroundTasks

/// 通知与后台刷新
///
/// 前提：TrollStore 安装的是**未签名**包，没有 APNs 权限，所以做不了系统级远程推送。
/// 这里做三件在未签名包上确实可行的事：
///   1. 前台/后台的**本地通知**（App 还在跑的时候）；
///   2. **未读角标**（图标上的数字）；
///   3. **BGAppRefreshTask** 定时静默拉取（iOS 只保证"会跑"，不保证频率，可能几十分钟一次）。
/// 锁屏/杀进程后的推送请用后台自带的 Bark 渠道。
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    /// 每个会话"已通知到的时间戳"（持久化）
    ///
    /// ⚠️ 以前是内存里的 Set，**App 重启 / 刷新列表就清空** → 未读会话会被反复弹一遍
    /// （2026-11-23 用户反馈"一直推送推送过的消息弹窗"）。
    /// 现在落 UserDefaults，并且判据改成"该会话的最后消息时间比已通知的新"才弹。
    private let marksKey = "xy.notifiedMarks"

    private func loadMarks() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: marksKey) as? [String: Double]) ?? [:]
    }

    private func saveMarks(_ map: [String: Double]) {
        UserDefaults.standard.set(map, forKey: marksKey)
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[通知] 授权失败:", error.localizedDescription)
            } else {
                print("[通知] 授权状态:", granted)
            }
        }
    }

    /// 角标：iOS 16+ 用 setBadgeCount，老系统用 applicationIconBadgeNumber
    func updateBadge(_ count: Int) {
        DispatchQueue.main.async {
            if #available(iOS 16.0, *) {
                UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in }
            } else {
                UIApplication.shared.applicationIconBadgeNumber = max(0, count)
            }
        }
    }

    /// 有新未读时弹本地通知（**只有比上次通知更新的消息才弹**，刷新列表不会重弹）
    func handleConversations(_ conversations: [Conversation], accountName: String) {
        let unread = conversations.filter { $0.unreadCount > 0 }
        updateBadge(unread.reduce(0) { $0 + $1.unreadCount })

        var marks = loadMarks()
        var changed = false
        for conv in unread {
            let last = conv.lastMessageTime
            // 关键判据：这条消息已经通知过（时间不新）就跳过，刷新/重启都不会重弹
            guard last > (marks[conv.cid] ?? 0) else { continue }
            marks[conv.cid] = last
            changed = true
            let fingerprint = "\(conv.cid)-\(Int(last))"

            let content = UNMutableNotificationContent()
            content.title = conv.otherUserName.isEmpty ? "新消息" : conv.otherUserName
            let summary = conv.lastMessageSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = summary.isEmpty ? "收到一条新消息" : summary
            content.sound = .default
            content.badge = NSNumber(value: unread.reduce(0) { $0 + $1.unreadCount })
            content.threadIdentifier = conv.cid
            if !accountName.isEmpty {
                content.subtitle = accountName
            }
            let request = UNNotificationRequest(identifier: fingerprint,
                                                content: content,
                                                trigger: nil)  // nil = 立即
            center.add(request)
        }
        if changed { saveMarks(marks) }
    }

    /// 进后台前清掉角标（可选：如果你希望"打开 App 即已读"）
    func clearBadge() {
        updateBadge(0)
    }
}

/// 负责：通知前台展示样式 + 注册后台刷新任务
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let bgTaskID = "com.xianyu.onlinekefu.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.requestAuthorization()

        // 不再注册 BGAppRefreshTask：未签名包经常被系统拒绝，且后台唤醒会顺带打闲鱼接口，
        // 收益低于风险（2026-11-22 撤掉）。锁屏推送交给后台的 Bark 渠道。
        return true
    }

    /// App 在前台时也把通知显示成横幅（默认前台不显示）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

}
