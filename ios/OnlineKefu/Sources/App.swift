import SwiftUI

@main
struct OnlineKefuApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            ConversationListView()
                .tabItem { Label("消息", systemImage: "bubble.left.and.bubble.right.fill") }

            // 网页版：内嵌整个后台 Web 端，商品/订单/卡券/智能客服等全部功能都在这里
            WebConsoleView(serverURL: AppSettings.serverURL,
                           token: state.token,
                           refreshToken: state.refreshToken,
                           username: state.username)
                .tabItem { Label("网页版", systemImage: "safari.fill") }

            AccountListView()
                .tabItem { Label("账号", systemImage: "person.2.circle.fill") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let bubbleSelf = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let bubbleOther = Color(uiColor: .secondarySystemBackground)
}

// MARK: - 通用小件

struct ErrorBanner: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.9))
            .cornerRadius(8)
            .padding(.horizontal, 12)
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

/// 头像：没图时显示昵称首字
struct AvatarView: View {
    let url: String
    let name: String
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let u = URL(string: url), !url.isEmpty {
                AsyncImage(url: u) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            Theme.accent.opacity(0.15)
            Text(String(name.prefix(1)))
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(Theme.accent)
        }
    }
}

extension Double {
    /// 毫秒时间戳 → 「12:34」/「昨天」/「11-20」
    var chatTimeText: String {
        guard self > 0 else { return "" }
        let date = Date(timeIntervalSince1970: self > 10_000_000_000 ? self / 1000 : self)
        let cal = Calendar.current
        let fmt = DateFormatter()
        if cal.isDateInToday(date) {
            fmt.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            return "昨天"
        } else {
            fmt.dateFormat = "MM-dd"
        }
        return fmt.string(from: date)
    }
}
