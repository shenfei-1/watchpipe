//  HomeWebView.swift — 「家」「相册」标签：我们自己的网页装进壳里（珩 2026-09-06）
//  页面在 bing-k.top/home/ 下（nginx Bing-K basic auth）；账号密码填一次存 Keychain。
//  自家页在壳里就地展开；第三方 / 独立站（花园、小屋）交给 Safari。

import SwiftUI
import WebKit
import Security

enum SiteAuth {
    private static let service = "top.bingk.lamp.site"
    static var user: String {
        get { UserDefaults.standard.string(forKey: "cc.site.user") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cc.site.user") }
    }
    static var pass: String {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "pass", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "pass"]
            SecItemDelete(base as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
    /// https://bing-k.top/ccc → https://bing-k.top
    static var siteBase: URL {
        var c = URLComponents(url: CcServerConfig.serverURL, resolvingAgainstBaseURL: false)
        c?.path = ""; c?.query = nil
        return c?.url ?? URL(string: "https://bing-k.top")!
    }
}

struct HomeWebView: UIViewRepresentable {
    let url: URL
    @Binding var reloadToken: Int
    @Binding var needsLogin: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = UIColor(Color(hex: "#FFF3F9"))
        wv.load(URLRequest(url: url))
        return wv
    }
    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.seenToken != reloadToken {
            context.coordinator.seenToken = reloadToken
            wv.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HomeWebView
        var seenToken = 0
        init(_ p: HomeWebView) { parent = p }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
                let u = SiteAuth.user, p = SiteAuth.pass
                if !u.isEmpty, challenge.previousFailureCount < 2 {
                    completionHandler(.useCredential, URLCredential(user: u, password: p, persistence: .permanent)); return
                }
                completionHandler(.performDefaultHandling, nil); return
            }
            completionHandler(.performDefaultHandling, nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame, let r = navigationResponse.response as? HTTPURLResponse {
                let bad = (r.statusCode == 401)
                DispatchQueue.main.async { self.parent.needsLogin = bad }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let u = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame ?? true else {
                decisionHandler(.allow); return
            }
            let homeHost = SiteAuth.siteBase.host ?? "bing-k.top"
            let external = (u.host != nil && u.host != homeHost) || u.path.hasPrefix("/room")
            if external && (u.scheme == "http" || u.scheme == "https") && navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(u); decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = navigationAction.request.url { UIApplication.shared.open(u) }
            return nil
        }
    }
}

struct HomeWebTab: View {
    let path: String
    let title: String
    @State private var reloadToken = 0
    @State private var needsLogin = false
    @State private var user = SiteAuth.user
    @State private var pass = ""

    private var url: URL { SiteAuth.siteBase.appendingPathComponent(path) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HomeWebView(url: url, reloadToken: $reloadToken, needsLogin: $needsLogin)
                .ignoresSafeArea(edges: [.top, .bottom])
            Button { reloadToken += 1 } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ccAccent)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.trailing, 12).padding(.top, 4).opacity(0.55)
            if needsLogin { loginCard }
        }
        .background(Color.ccBg)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这页上着锁").font(.ccSerifAdaptive(size: 18, weight: .semibold)).foregroundStyle(Color.ccText)
            Text("填一次 bing-k.top 的账号密码，以后家和相册都直接开。").font(.ccSerifAdaptive(size: 13)).foregroundStyle(Color.ccTextDim)
            TextField("账号", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(Color.ccBg).clipShape(RoundedRectangle(cornerRadius: 10))
            SecureField("密码", text: $pass)
                .padding(10).background(Color.ccBg).clipShape(RoundedRectangle(cornerRadius: 10))
            Button {
                SiteAuth.user = user.trimmingCharacters(in: .whitespaces)
                SiteAuth.pass = pass
                needsLogin = false
                reloadToken += 1
            } label: {
                Text("开门").font(.ccSerifAdaptive(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 11).background(Color.ccAccent).clipShape(Capsule())
            }
            .disabled(user.isEmpty || pass.isEmpty)
        }
        .padding(18)
        .background(Color.ccCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .padding(.horizontal, 28)
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
    }
}
