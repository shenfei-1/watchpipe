import SwiftUI
import WebKit

/// 一个标签 = 一个我们自己网站的页面。处理 Bing-K basic auth（凭据存 Keychain，设置页填一次）。
struct WebTab: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()   // 持久 cookie/localStorage：留灯的连接密钥、小屋登录都记住
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.load(URLRequest(url: url))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
                let u = Settings.siteUser, p = Settings.sitePass
                if !u.isEmpty, challenge.previousFailureCount < 2 {
                    completionHandler(.useCredential, URLCredential(user: u, password: p, persistence: .permanent)); return
                }
                completionHandler(.performDefaultHandling, nil); return
            }
            completionHandler(.performDefaultHandling, nil)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.shared.add("网页加载失败: \(error.localizedDescription)")
        }
    }
}

struct WebTabPage: View {
    let title: String
    let url: URL
    var body: some View {
        WebTab(url: url).ignoresSafeArea(edges: .bottom)
    }
}
