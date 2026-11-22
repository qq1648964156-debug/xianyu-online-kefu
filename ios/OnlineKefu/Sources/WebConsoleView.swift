import SwiftUI
import WebKit

/// 网页版容器：直接内嵌后台 Web 端，功能与网页完全一致（含商品/订单/卡券/智能客服等）。
///
/// 为什么要有它：原生只做"聊天"这一条主线，商品管理、订单、卡券、智能客服配置这些页面
/// 在手机上重写一遍成本极高且永远追不上网页迭代。内嵌后**网页端绝大部分功能立刻可用**，
/// 原生界面保留高频操作（会话列表 / 聊天发送）。
///
/// 关键点：注入登录态。WebView 与 App 不同源的话需要重新登录，这里在 documentStart
/// 把 auth_token / refresh_token / user_info / auth-storage 写进 localStorage，
/// 网页一打开就是已登录状态（与 App 用同一套 token）。
struct WebConsoleView: View {
    let serverURL: URL
    let token: String?
    let refreshToken: String?
    let username: String?
    /// 跨 tab 跳转：例如从会话信息点"订单管理"→ 网页版 /orders
    let pendingPath: String?

    @EnvironmentObject var state: AppState
    @StateObject private var model = WebViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    WebViewContainer(model: model,
                                     serverURL: serverURL,
                                     token: token,
                                     refreshToken: refreshToken,
                                     username: username)
                    if model.loading {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                            .tint(Theme.accent)
                    }
                }
            }
            .navigationTitle(model.title.isEmpty ? "网页版" : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!model.canGoBack)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { model.goForward() } label: { Label("前进", systemImage: "chevron.forward") }
                        Button { model.reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        Button { model.goHome(serverURL) } label: { Label("回到首页", systemImage: "house") }
                        Button {
                            UIApplication.shared.open(model.currentURL ?? serverURL)
                        } label: { Label("用 Safari 打开", systemImage: "safari") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: pendingPath) { path in
            guard let path, !path.isEmpty else { return }
            model.load(path: path, serverURL: serverURL)
            _ = state.consumePendingWebPath()
        }
    }

}

final class WebViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var progress: Double = 0
    @Published var title = ""
    @Published var currentURL: URL?

    private(set) var webView: WKWebView?
    private var serverHost = ""
    private var observations: [NSKeyValueObservation] = []

    /// 懒创建 WKWebView（makeUIView 里调用；重复调用返回同一个实例）
    @discardableResult
    func ensureWebView(serverURL: URL, token: String?, refreshToken: String?, username: String?) -> WKWebView {
        if let webView { return webView }
        serverHost = serverURL.host ?? ""

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        // 注入登录态：网页端读的是 localStorage 里的这几个键
        if let token, !token.isEmpty {
            let js = Self.authScript(token: token,
                                     refreshToken: refreshToken ?? "",
                                     username: username ?? "")
            cfg.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        // 输入框字号必须 >=16px，否则 iOS 聚焦时会把整页放大（用户反馈"进去就放大、要手动缩回"）。
        // 用单引号包 CSS，避免 Swift 字符串里再转义双引号。
        let css = "input,textarea,select{font-size:16px !important}html{-webkit-text-size-adjust:100%}"
        let cssJS = "var s=document.createElement('style');s.textContent='" + css + "';document.documentElement.appendChild(s);"
        cfg.userContentController.addUserScript(WKUserScript(
            source: cssJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        webView = wv

        observations = [
            wv.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in
                DispatchQueue.main.async { self?.canGoBack = v.canGoBack }
            },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] v, _ in
                DispatchQueue.main.async { self?.canGoForward = v.canGoForward }
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in
                DispatchQueue.main.async { self?.progress = v.estimatedProgress }
            },
            wv.observe(\.title, options: [.new]) { [weak self] v, _ in
                DispatchQueue.main.async { self?.title = v.title ?? "" }
            },
        ]

        // 带 app_embed=1：网页端据此隐藏自带的侧边栏/顶栏/标签栏，
        // 否则外壳与网页两套导航叠在一起，内容被挤压（2026-11-22 iPhone 实拍）。
        var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.removeAll { $0.name == "app_embed" }
        items.append(URLQueryItem(name: "app_embed", value: "1"))
        comps?.queryItems = items
        wv.load(URLRequest(url: comps?.url ?? serverURL))
        return wv
    }

    private static func authScript(token: String, refreshToken: String, username: String) -> String {
        // 用 JSON 编码避免引号/中文把 JS 弄坏
        func q(_ s: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [s])
            let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(arr.dropFirst().dropLast())
        }
        let user = "{\"username\":\(q(username))}"
        return """
        (function(){
          try {
            localStorage.setItem('auth_token', \(q(token)));
            localStorage.setItem('refresh_token', \(q(refreshToken)));
            localStorage.setItem('user_info', \(q(user)));
            localStorage.setItem('auth-storage', JSON.stringify({
              state: { token: \(q(token)), refreshToken: \(q(refreshToken)), user: \(user), isAuthenticated: true },
              version: 0
            }));
          } catch (e) {}
        })();
        """
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func goHome(_ url: URL) { webView?.load(URLRequest(url: url)) }

    /// 打开站内指定路由（自动带上 app_embed=1，保持"去壳"模式）
    func load(path: String, serverURL: URL) {
        var comps = URLComponents(url: URL(string: path, relativeTo: serverURL) ?? serverURL,
                                  resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.removeAll { $0.name == "app_embed" }
        items.append(URLQueryItem(name: "app_embed", value: "1"))
        comps?.queryItems = items
        if let url = comps?.url { webView?.load(URLRequest(url: url)) }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        currentURL = webView.url
        title = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
    }

    /// 站内链接留在 WebView；站外（闲鱼、支付、第三方）交给系统浏览器
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let host = url.host ?? ""
        // 非 http(s)（tel/mailto/自定义 scheme）→ 交系统处理
        if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "data", "blob"].contains(scheme) {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        // 子框架（iframe）一律放行：91卡券库 / 闲管家库 都是 iframe 嵌本地桥接面板，
        // 它们的主机名跟后台不同（127.0.0.1:7890 / :36301），过去被当成"站外链接"跳去 Safari，
        // iframe 里直接白屏（2026-11-22 用户反馈）。
        if let target = navigationAction.targetFrame, !target.isMainFrame {
            return decisionHandler(.allow)
        }
        if navigationAction.targetFrame == nil {
            // target=_blank：同站留在 WebView，站外交系统浏览器
            if !serverHost.isEmpty, !host.isEmpty, !host.hasSuffix(serverHost) {
                UIApplication.shared.open(url)
            } else {
                webView.load(navigationAction.request)
            }
            return decisionHandler(.cancel)
        }
        if !serverHost.isEmpty, !host.isEmpty, !host.hasSuffix(serverHost), host != serverHost {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if let host = url.host, !serverHost.isEmpty, !host.hasSuffix(serverHost) {
                UIApplication.shared.open(url)
            } else {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }
}

private struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var model: WebViewModel
    let serverURL: URL
    let token: String?
    let refreshToken: String?
    let username: String?

    func makeUIView(context: Context) -> WKWebView {
        model.ensureWebView(serverURL: serverURL, token: token,
                            refreshToken: refreshToken, username: username)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
