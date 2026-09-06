import Foundation
import Security

enum Keychain {
    private static let service = "top.bingk.watchpipe"
    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // 锁屏后后台任务也要读得到
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

enum Settings {
    static var serverURL: String {
        get { Keychain.get("server_url") ?? "https://bing-k.top/api/health/ingest" }
        set { Keychain.set(newValue, for: "server_url") }
    }
    static var secret: String {
        get { Keychain.get("secret") ?? "" }
        set { Keychain.set(newValue, for: "secret") }
    }
    /// bing-k.top 上带 basic auth 的页面（小屋等）用的账号密码，填一次
    static var siteUser: String {
        get { Keychain.get("site_user") ?? "" }
        set { Keychain.set(newValue, for: "site_user") }
    }
    static var sitePass: String {
        get { Keychain.get("site_pass") ?? "" }
        set { Keychain.set(newValue, for: "site_pass") }
    }
}
