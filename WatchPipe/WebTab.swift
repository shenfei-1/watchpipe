import SwiftUI
import WebKit

/// 一个标签 = 一个我们自己网站的页面。处理 Bing-K basic auth（凭据存 Keychain，心率页填一次）。
/// 填完密码不用重开 app：页面上一次被 401 拒绝的话，回到这个标签会自动重试；顶部也有刷新。
struct WebTab: UIViewRepresentable {
    let url: URL
    @Binding var reloadToken: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()   // 持久 cookie/localStorage：留灯的连接密钥、小屋登录都记住
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.seenToken != reloadToken {
            context.coordinator.seenToken = reloadToken
            uiView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var seenToken = 0
        var lastStatus = 0
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
                let u = Settings.siteUser, p = Settings.sitePass
                if !u.isEmpty, challenge.previousFailureCount < 2 {
                    completionHandler(.useCredential, URLCredential(user: u, password: p, persistence: .forSession)); return
                }
                completionHandler(.performDefaultHandling, nil); return
            }
            completionHandler(.performDefaultHandling, nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let r = navigationResponse.response as? HTTPURLResponse, navigationResponse.isForMainFrame {
                lastStatus = r.statusCode
                if let u = r.url?.absoluteString { WebTabPage.lastFailed[u] = (r.statusCode == 401) }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.shared.add("网页加载失败: \(error.localizedDescription)")
        }
    }
}

struct WebTabPage: View {
    let title: String
    let url: URL
    @State private var reloadToken = 0
    @State private var coordinatorStatus = 0
    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebTab(url: url, reloadToken: $reloadToken).ignoresSafeArea(edges: .bottom)
            Button { reloadToken += 1 } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    .padding(8).background(.ultraThinMaterial, in: Circle())
            }
            .padding(.trailing, 10).padding(.top, 6).opacity(0.7)
        }
        .onAppear {
            // 之前被 401 拒过、现在有密码了 → 自动重试一次
            if !Settings.siteUser.isEmpty && Self.lastFailed[url.absoluteString] == true {
                Self.lastFailed[url.absoluteString] = false; reloadToken += 1
            }
        }
    }
    static var lastFailed: [String: Bool] = [:]
}
