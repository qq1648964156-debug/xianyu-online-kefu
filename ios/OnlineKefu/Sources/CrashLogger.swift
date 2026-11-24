import Foundation
import Darwin

/// 轻量崩溃取证：把崩溃类型 + 调用栈写进 App 沙盒的 Documents/crash-last.txt。
///
/// 为什么需要它：Swift 的致命错误（数组越界、fatalError、重复 ID）走的是 **signal**，
/// 不是 NSException，Xcode 不在场时只能靠系统 .ips，用户不会捞。
/// 这里在崩溃瞬间尽力落盘一份，重启后可在「设置 → 诊断」里查看并复制给开发。
enum CrashLogger {
    private static let fileName = "crash-last.txt"
    private static let maxBytes = 64 * 1024

    static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    /// 装钩子（App 启动最早时机调用一次）
    static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let head = "EXCEPTION \(ex.name.rawValue)\nreason: \(ex.reason ?? "-")\n"
            CrashLogger.write(head + ex.callStackSymbols.joined(separator: "\n"))
        }

        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig, { s in
                let syms = Thread.callStackSymbols.joined(separator: "\n")
                CrashLogger.write("SIGNAL \(s)\n" + syms)
                // 恢复默认处理，让系统也能生成 .ips（便于进一步定位）
                signal(s, SIG_DFL)
                raise(s)
            })
        }
    }

    /// 写日志（signal handler 里调用，尽量用最朴素的 POSIX 写入）
    static func write(_ text: String) {
        guard let url = logURL else { return }
        let payload = "\n===== \(timestamp()) =====\n\(text)\n"
        guard let data = payload.data(using: .utf8) else { return }

        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = Darwin.write(fd, base, data.count)
            }
        }
        close(fd)
        trimIfNeeded(url)
    }

    /// 最近一次崩溃内容（设置页展示用）
    static func lastCrash() -> String? {
        guard let url = logURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 只回最后一段（一次崩溃）
        let parts = trimmed.components(separatedBy: "=====")
        if parts.count >= 3 {
            return "=====" + parts[parts.count - 2] + "=====" + parts[parts.count - 1].prefix(4000)
        }
        return String(trimmed.suffix(4000))
    }

    static func clear() {
        if let url = logURL { try? FileManager.default.removeItem(at: url) }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let keep = String(text.suffix(maxBytes / 2))
        try? keep.write(to: url, atomically: true, encoding: .utf8)
    }
}
