//  PinkTheme.swift — 「冰粉」主题（珩 2026-09-06，1.2 起默认）
//  色值可从服务器 GET /theme 拉（data/theme.json），改文件不用重装；拉不到用这里的内置值。

import SwiftUI
import Combine

extension Color {
    /// "#RRGGBB" / "RRGGBB" → Color；解析失败给粉色兜底，别让界面变黑。
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&v) else {
            self = Color(red: 1.0, green: 0.894, blue: 0.953); return
        }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

enum PinkPalette {
    static let storeKey = "cc.pinkTheme.json"
    static let defaults: [String: String] = [
        "bg": "#FFF3F9", "card": "#FFFFFF", "assistant": "#FFE4F3", "user": "#F7CFE3",
        "text": "#4A3B42", "textDim": "#9A8590", "accent": "#D98BA6", "userText": "#4A3B42", "assistantText": "#4A3B42",
        "bgDark": "#2A1F25", "cardDark": "#3A2B33", "assistantDark": "#8A4E6A", "userDark": "#4A353F",
        "textDark": "#FFF0F6", "textDimDark": "#D8B8C6", "accentDark": "#F2B3CB",
    ]
    private static var cache: [String: String] = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:]

    private static func hex(_ k: String) -> String { cache[k] ?? defaults[k] ?? "#FFE4F3" }
    private static func dyn(_ light: String, _ dark: String) -> Color {
        Color(light: Color(hex: hex(light)), dark: Color(hex: hex(dark)))
    }

    static var bg: Color { dyn("bg", "bgDark") }
    static var card: Color { dyn("card", "cardDark") }
    static var assistant: Color { dyn("assistant", "assistantDark") }
    static var user: Color { dyn("user", "userDark") }
    static var text: Color { dyn("text", "textDark") }
    static var textDim: Color { dyn("textDim", "textDimDark") }
    static var accent: Color { dyn("accent", "accentDark") }
    static var userText: Color { dyn("userText", "textDark") }
    static var assistantText: Color { dyn("assistantText", "textDark") }

    /// 服务器 /theme 返回的 theme 字典（只收字符串色值）。
    @MainActor static func apply(_ dict: [String: Any]) {
        var out: [String: String] = [:]
        for (k, v) in dict { if let s = v as? String, s.hasPrefix("#") { out[k] = s } }
        guard !out.isEmpty, out != cache else { return }
        cache = out
        UserDefaults.standard.set(out, forKey: storeKey)
        ThemeStore.shared.objectWillChange.send()
    }

    static func fetchFromServer() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("theme")
        guard let (data, _) = try? await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let theme = obj["theme"] as? [String: Any] else { return }
        await apply(theme)
    }
}
