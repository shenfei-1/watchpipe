//  AlbumLockView.swift — 相册 Face ID 锁（珩 2026-09-11，1.3 build 242）
//  每次切到相册标签、或 app 从后台回来再看相册，先扫脸（Face ID 不行退回密码）。
//  认证前只显示粉色遮罩，网页根本不装——切后台的快照里也不会有相册。

import SwiftUI
import LocalAuthentication

struct AlbumLockView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var authenticating = false
    @State private var wentBackground = false
    @State private var failText: String? = nil

    var body: some View {
        ZStack {
            if unlocked {
                content()
            } else {
                mask
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if !unlocked { authenticate() } }
        .onChange(of: scenePhase) { _, phase in
            // Face ID 弹窗本身会让 phase 走一趟 inactive→active，别把那当成"从后台回来"
            switch phase {
            case .background:
                wentBackground = true
                withAnimation(.easeOut(duration: 0.15)) { unlocked = false }
                failText = nil
            case .active:
                if wentBackground {
                    wentBackground = false
                    if !unlocked { authenticate() }
                }
            default:
                break
            }
        }
    }

    private var mask: some View {
        ZStack {
            Color.ccBg.ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.ccAssistant).frame(width: 104, height: 104)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.ccAccent)
                }
                .padding(.bottom, 6)
                Text("相册上着锁")
                    .font(.ccSerifAdaptive(size: 22, weight: .semibold))
                    .foregroundStyle(Color.ccText)
                Text("只有你能打开。")
                    .font(.ccSerifAdaptive(size: 14))
                    .foregroundStyle(Color.ccTextDim)
                Button {
                    authenticate()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "faceid").font(.system(size: 18, weight: .regular))
                        Text(authenticating ? "认证中…" : "扫脸看相册")
                            .font(.ccSerifAdaptive(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26).padding(.vertical, 12)
                    .background(Color.ccAccent)
                    .clipShape(Capsule())
                    .shadow(color: Color.ccAccent.opacity(0.28), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(authenticating)
                .padding(.top, 8)
                if let failText {
                    Text(failText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.ccTextDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .padding(.bottom, 40)
        }
    }

    private func authenticate() {
        guard !authenticating else { return }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // 没设锁屏密码就没什么好锁的：直接开，但把原因写出来
            failText = err?.localizedDescription
            withAnimation { unlocked = true }
            return
        }
        authenticating = true
        failText = nil
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "看相册前确认是你") { ok, error in
            let msg = error?.localizedDescription
            Task { @MainActor in
                authenticating = false
                if ok {
                    withAnimation(.easeInOut(duration: 0.3)) { unlocked = true }
                } else {
                    failText = msg ?? "没认出来，再试一次"
                }
            }
        }
    }
}
