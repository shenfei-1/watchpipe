//
//  CcCompanionApp.swift
//  CcCompanion
//
//  Created by HoshimiMian on 2026/4/28.
//

import SwiftUI
import UIKit
import CoreText

@main
struct CcCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // 珩 2026-09-06 1.2：冷启动先出 Lamp 开屏（图 + 我每天一句），按 Enter 淡出进聊天
    @State private var showSplash = true
    @StateObject private var themeStore = ThemeStore.shared

    init() {
        // Build 218 r3 — XCUITest hook: when launched with UITEST_GROUP_UPLOAD_SMOKE=1
        // pre-populate UserDefaults so the test skips onboarding + lands directly on the
        // group chat tab pointed at the local demo server (8796). Has no effect at runtime.
        if ProcessInfo.processInfo.environment["UITEST_GROUP_UPLOAD_SMOKE"] == "1" {
            // Onboarding flag + feature toggle live in standard suite (per @AppStorage usage).
            let std = UserDefaults.standard
            std.set(true, forKey: "cc_onboarding_completed")
            std.set(true, forKey: "feature_group_view")
            std.set("",   forKey: "chat_last_seen_ts")
            // Server endpoint list lives in the app group suite (per CcServerConfig).
            if let ag = Optional(UserDefaults.standard) {
                ag.set(["http://127.0.0.1:8796"], forKey: "serverURLList")
                ag.set(["UITestDemo"],             forKey: "serverLabelList")
                ag.set(0,                          forKey: "serverActiveIndex")
                ag.set("http://127.0.0.1:8796",    forKey: "serverURL")
            }
            // Shared secret read from launchEnvironment (UITest injects via XCUIApplication.launchEnvironment).
            // Never hardcode a secret literal here — public repo leaks it (incident 2026-05-24).
            if let injected = ProcessInfo.processInfo.environment["CCC_UITEST_SHARED_SECRET"], !injected.isEmpty {
                CcServerConfig.setSharedSecret(injected)
            }
        }
        // Phase multi-server fallback (2026-05-11) — 旧版单 serverURL 一次性迁到新 endpoints 列表.
        CcServerConfig.migrateLegacySharedSecretIfNeeded()
        CcServerConfig.migrateLegacySingleURLIfNeeded()
        CcServerConfig.syncToAppGroup()
        AvatarDiskStore.migrateStoredAvatarPathsIfNeeded()
        Self.registerCustomFonts()
        #if os(iOS) && !targetEnvironment(macCatalyst)
        Task { @MainActor in
            PushTokenManager.shared.requestAuthorization()
        }
        #endif
    }

    private static func registerCustomFonts() {
        // 珩 2026-09-06：加 Cormorant Garamond（OFL，开屏花体 / 底栏英文）
        let names = [
            "SourceSerif4-Regular.otf",
            "SourceSerif4-Semibold.otf",
            "SourceHanSerifSC-Regular.otf",
            "SourceHanSerifSC-Bold.otf",
            "CormorantGaramond-300.ttf",
            "CormorantGaramond-300Italic.ttf",
            "CormorantGaramond-500.ttf",
            "CormorantGaramond-500Italic.ttf",
        ]
        for file in names {
            let n = (file as NSString).deletingPathExtension
            let ext = (file as NSString).pathExtension
            guard let url = Bundle.main.url(forResource: n, withExtension: ext) else {
                print("[CcFont] missing in bundle: \(file)")
                continue
            }
            var err: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
                print("[CcFont] register failed \(n): \(err.debugDescription)")
            }
        }
        let han = UIFont.fontNames(forFamilyName: "Source Han Serif SC")
        let serif = UIFont.fontNames(forFamilyName: "Source Serif 4")
        print("[CcFont] Cormorant = \(UIFont.fontNames(forFamilyName: "Cormorant Garamond"))")
        print("[CcFont] Source Han Serif SC fonts = \(han)")
        print("[CcFont] Source Serif 4 fonts = \(serif)")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .id(themeStore.paletteStamp)   // 服务器色值拉到 → 整棵重建，气泡当场换色
                    .ccSerifTheme()
                    .whatsNewGate()   // v1.2 新 build 首启弹 What's New
                if showSplash {
                    SplashView { withAnimation(.easeInOut(duration: 0.55)) { showSplash = false } }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("Paste") {
                    NotificationCenter.default.post(name: .ccPasteFromClipboard, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let ccPasteFromClipboard = Notification.Name("ccPasteFromClipboard")
}
