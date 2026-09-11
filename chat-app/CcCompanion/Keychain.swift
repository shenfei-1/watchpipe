//  Keychain.swift — 心率管道的 secret / 服务器地址 / 状态（珩 2026-09-11，1.3 build 242，从 WatchPipe 搬来）
//  secret 存 Keychain（AfterFirstUnlock：锁屏后后台投递也读得到）；状态位存 UserDefaults。

import Foundation
import Security

@MainActor
enum HealthKeychain {
    private static let service = "top.bingk.lamp.health"

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

@MainActor
enum HealthSettings {
    /// 上传口固定走我们自己的服务器（跟 WatchPipe 一样，secret 用 query 参数带）。
    static let defaultServerURL = "https://bing-k.top/api/health/ingest"
    static var serverURL: String {
        get { HealthKeychain.get("server_url") ?? defaultServerURL }
        set { HealthKeychain.set(newValue, for: "server_url") }
    }
    static var secret: String {
        get { HealthKeychain.get("secret") ?? "" }
        set { HealthKeychain.set(newValue, for: "secret") }
    }
}

/// 设置页状态行用的几个标记（UserDefaults）。
@MainActor
enum HealthStatus {
    static let authorizedKey = "hp.authorized"
    static let bgDeliveryKey = "hp.bgDeliveryOn"
    static let lastUploadAtKey = "hp.lastUploadAt"
    static let lastUploadCountKey = "hp.lastUploadCount"

    static var authorized: Bool { UserDefaults.standard.bool(forKey: authorizedKey) }
    static var backgroundDeliveryOn: Bool { UserDefaults.standard.bool(forKey: bgDeliveryKey) }
    static var lastUploadAt: Date? { UserDefaults.standard.object(forKey: lastUploadAtKey) as? Date }
    static var lastUploadCount: Int { UserDefaults.standard.integer(forKey: lastUploadCountKey) }

    static func recordUpload(count: Int?) {
        UserDefaults.standard.set(Date(), forKey: lastUploadAtKey)
        if let count { UserDefaults.standard.set(count, forKey: lastUploadCountKey) }
    }
}
