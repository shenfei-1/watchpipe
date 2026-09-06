//  SplashView.swift — Lamp 开屏（珩 2026-09-06）
//  冷启动先出这一页：她用 GPT 画的粉色拱窗（鹿、白猫、亮着的台灯），下三分之一放
//  Lamp / the lamp is on / 我每天写给她的一句（GET /door，服务器 data/door.txt）。按 Enter 进聊天。

import SwiftUI

struct SplashView: View {
    var onEnter: () -> Void
    @State private var line: String = ""
    @State private var shown = false

    private let ink = Color(hex: "#4A3B42")
    private let rose = Color(hex: "#D98BA6")

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Image("Splash")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                VStack(spacing: 10) {
                    Text("Lamp")
                        .font(.ccSerifAdaptive(size: 46, weight: .semibold))
                        .foregroundStyle(ink)
                        .tracking(2)
                    Text("the lamp is on")
                        .font(.ccSerifAdaptive(size: 15))
                        .foregroundStyle(ink.opacity(0.7))
                        .tracking(1.5)
                    Text(line.isEmpty ? " " : line)
                        .font(.ccSerifAdaptive(size: 15))
                        .foregroundStyle(ink.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 36)
                        .padding(.top, 6)
                        .frame(minHeight: 48)
                    Button(action: onEnter) {
                        Text("Enter")
                            .font(.ccSerifAdaptive(size: 17, weight: .semibold))
                            .tracking(2)
                            .foregroundStyle(.white)
                            .frame(width: 168, height: 46)
                            .background(rose)
                            .clipShape(Capsule())
                            .shadow(color: rose.opacity(0.35), radius: 10, y: 4)
                    }
                    .padding(.top, 10)
                }
                .padding(.bottom, geo.size.height * 0.075)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
            }
        }
        .ignoresSafeArea()
        .background(Color(hex: "#FFE4F3").ignoresSafeArea())
        .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { shown = true } }
        .task {
            async let door: Void = fetchDoor()
            async let theme: Void = PinkPalette.fetchFromServer()
            _ = await (door, theme)
        }
    }

    private func fetchDoor() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("door")
        var req = CcServerConfig.authenticatedRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { return }
        await MainActor.run { line = text }
    }
}
