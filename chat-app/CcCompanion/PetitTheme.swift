//  PetitTheme.swift — 「小小世界」聊天页皮（珩 2026-09-15，1.4 build 245）
//
//  色值和皮的数量自冰冰 9/15 发我的 mon_petit_monde.html；字号/行高/内边距/最大宽/行距按 244（ChatMetrics），她 16:38 看了真机定的（副本 /root/backups/companion-web/mon_petit_monde_0915.html），
//  取的是它 @media(max-width:720px) 手机断点的值。她的设计，我只搬不改；改数只改这一个文件。
//
//  html 量到的：
//    body      背景 linear-gradient(135deg,#f2e9ee,#ece1e9 55%,#eee7ed) + 两层白点（17px / 23px 网格，r≈1，透明度 .7/.6）
//    header    高 72，bg rgba(255,252,253,.72)，底边 1px #e7d9e1，品牌字 16px serif #876e7e
//    .eyebrow  11px，字距 .26em，大写，#ad8c9f，居中，下边距 24（"SEPTEMBER 08 · OUR CONVERSATION"）
//    .chat-bubble  bg #fffdfb，边 1px #e6d8df，圆角 15，内边距 20×23，阴影 0 5 18 rgba(125,95,114,.04)，
//                  字 "Noto Serif SC"/"Songti SC" 15px（手机 14px），行高 1.8，最大宽 86%
//    .user     bg #e8c5d7（边同上）
//    .star     40 圆，边 1px #e8dbe2，bg #fff8fb，✧ 18px #c99ab1，右距 8
//    .time     10px #9c8794，上 9 下 28；bot-time 左缩 8%，user-time 右缩 5%；AI 侧 "10:00 · Caelum"
//    .seal     斜体 14px #ae8da0，"sealed with a little love ♡"
//    .input    高 70，圆角 27，边 1px #e2d4dc，bg rgba(255,253,251,.85)，左内距 24 右 13，
//              占位 serif 15px #b49da9 "记录此刻的想法..."；.send 47 圆，bg #f0e3e9，➤ 21px #b48ca1
//    nav       高 74，圆角 25，bg rgba(255,253,252,.94)，边 1px #e4d8df，阴影 0 10 35 rgba(105,79,96,.1)，
//              离底 18，宽 96%；图标 23px，字 12px Georgia；选中 #b77f99，未选 #9a8290
//    main      手机断点两侧 18

import SwiftUI
import UIKit
import Combine

/// 开关：只在「冰粉」主题下生效；关掉就回 243 的样子。持久化在 UserDefaults。
final class PetitStore: ObservableObject {
    static let shared = PetitStore()
    static let storeKey = "cc.petit.enabled"
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.storeKey)
            // 根视图靠 paletteStamp .id() 重建，行高缓存/颜色一起换
            ThemeStore.shared.paletteStamp += 1
        }
    }
    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.storeKey) as? Bool ?? true
    }
}

enum PetitStyle {
    /// 当前是否在用这套皮
    static var active: Bool { ThemeStore.shared.theme == .pink && PetitStore.shared.enabled }

    // MARK: 色（浅色；html 没有深色版，深色沿用冰粉的深色值）
    static let bgTop = Color(hex: "#F2E9EE")
    static let bgMid = Color(hex: "#ECE1E9")
    static let bgBottom = Color(hex: "#EEE7ED")
    static let paper = Color(hex: "#FFFDFB")
    static let paperBorder = Color(hex: "#E6D8DF")
    static let userFill = Color(hex: "#E8C5D7")
    static let ink = Color(hex: "#866B7D")
    static let muted = Color(hex: "#A28C99")
    static let timeText = Color(hex: "#9C8794")
    static let eyebrow = Color(hex: "#AD8C9F")
    static let starFg = Color(hex: "#C99AB1")
    static let starBg = Color(hex: "#FFF8FB")
    static let starBorder = Color(hex: "#E8DBE2")
    static let seal = Color(hex: "#AE8DA0")
    static let inputBorder = Color(hex: "#E2D4DC")
    static let inputBg = Color(red: 1.0, green: 253/255, blue: 251/255).opacity(0.85)
    static let placeholder = Color(hex: "#B49DA9")
    static let sendBg = Color(hex: "#F0E3E9")
    static let sendFg = Color(hex: "#B48CA1")
    static let navBg = Color(red: 1.0, green: 253/255, blue: 252/255).opacity(0.94)
    static let navBorder = Color(hex: "#E4D8DF")
    static let navText = Color(hex: "#9A8290")
    static let navActive = Color(hex: "#B77F99")
    static let headerBg = Color(red: 1.0, green: 252/255, blue: 253/255).opacity(0.72)
    static let headerBorder = Color(hex: "#E7D9E1")
    static let brand = Color(hex: "#876E7E")
    static let shadow = Color(red: 125/255, green: 95/255, blue: 114/255).opacity(0.04)
    static let navShadow = Color(red: 105/255, green: 79/255, blue: 96/255).opacity(0.10)
    static let inputShadow = Color(red: 121/255, green: 91/255, blue: 110/255).opacity(0.08)   // var(--shadow) 0 10 28

    // MARK: 数（气泡/行距的数已并进 ChatMetrics，按 active 分流；这里放其余的）
    static let bodyFontSize: CGFloat = 14          // .chat-bubble @720
    static let bodyLineHeightMultiple: CGFloat = 1.56   // 她 9/15 16:38 定的：字号/行高/内边距/最大宽都按 244（13.5 / 1.56 / 8×13 / 63%），html 的 14 / 1.8 / 20×23 / 86% 在手机上太胖；下面几条数只留作记录
    static let bubbleRadius: CGFloat = 15
    static let bubblePaddingVertical: CGFloat = 20
    static let bubblePaddingHorizontal: CGFloat = 23
    static let bubbleMaxWidthFraction: CGFloat = 0.86
    static let sideInset: CGFloat = 18             // main padding @720
    static let starSize: CGFloat = 40
    static let starGap: CGFloat = 8
    static let timeFontSize: CGFloat = 10
    static let timeTopGap: CGFloat = 9
    static let rowGap: CGFloat = 28                // .time margin-bottom
    static let rowGapGrouped: CGFloat = 12         // .chat-line margin-bottom
    static let eyebrowFontSize: CGFloat = 11
    static let eyebrowTracking: CGFloat = 11 * 0.26
    static let eyebrowBottom: CGFloat = 24
    static let sealFontSize: CGFloat = 14
    static let inputHeight: CGFloat = 36           // html 70；她 9/15 16:40 说底下太高，要一半
    static let inputRadius: CGFloat = 27
    static let inputLeading: CGFloat = 16          // html 24，随高度一起收
    static let inputTrailing: CGFloat = 13
    static let sendSize: CGFloat = 34              // html 47，一半高度版
    static let sendIconSize: CGFloat = 17
    static let navHeight: CGFloat = 48             // html 74，一半高度版
    static let navRadius: CGFloat = 25
    static let navBottom: CGFloat = 8              // html 18，一半高度版
    static let navIconSize: CGFloat = 19           // html 23，一半高度版
    static let navIconFrame: CGFloat = 26          // 图标外框（原 44）
    static let navTitleFontSize: CGFloat = 13      // 底栏英文（原 Cormorant 16）
    static let navTitleSize: CGFloat = 12
    static let headerHeight: CGFloat = 72

    // MARK: 字体（html：Georgia 斜体 / "Noto Serif SC"→iOS 用内置 Songti SC，和 CcFont 里 ccSerif 一路）
    static func body(_ size: CGFloat) -> Font { .custom("STSongti-SC-Regular", size: size) }
    static func italic(_ size: CGFloat) -> Font { .custom("CormorantGaramond-500Italic", size: size) }
    static func label(_ size: CGFloat) -> Font { .custom("CormorantGaramond-500", size: size) }

    /// 正文行距补差（STSongti 自身行高和字号×1.8 的差）
    static func bodyLineSpacing(fontSize: CGFloat) -> CGFloat {
        let natural = (UIFont(name: "STSongti-SC-Regular", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)).lineHeight
        return max(0, (fontSize * bodyLineHeightMultiple).rounded() - natural)
    }

    /// 眉题："SEPTEMBER 15 · OUR CONVERSATION"（从分隔行 id "sep_<ts>" 里取日期）
    static func eyebrowText(fromSeparatorId id: String) -> String? {
        let ts = id.hasPrefix("sep_") ? String(id.dropFirst(4)) : id
        guard let d = ChatMetrics.parse(ts) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM dd"
        return f.string(from: d).uppercased() + " · OUR CONVERSATION"
    }
}

// MARK: - 小视图（都只在 PetitStyle.active 时被挂上）

/// 页面底色：135° 三段渐变 + 两层白点
struct PetitBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: PetitStyle.bgTop, location: 0),
                    .init(color: PetitStyle.bgMid, location: 0.55),
                    .init(color: PetitStyle.bgBottom, location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Canvas { ctx, size in
                // radial-gradient(circle at 12% 20%, white .7) background-size 17px → 每 17pt 一个点，点心在格子的 (12%,20%)
                Self.dots(&ctx, size: size, step: 17, ox: 0.12, oy: 0.20, alpha: 0.7)
                Self.dots(&ctx, size: size, step: 23, ox: 0.80, oy: 0.65, alpha: 0.6)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private static func dots(_ ctx: inout GraphicsContext, size: CGSize, step: CGFloat, ox: CGFloat, oy: CGFloat, alpha: Double) {
        let dot = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))
        var y: CGFloat = oy * step
        while y < size.height {
            var x: CGFloat = ox * step
            while x < size.width {
                ctx.fill(dot.offsetBy(dx: x, dy: y), with: .color(.white.opacity(alpha)))
                x += step
            }
            y += step
        }
    }
}

/// 顶栏底：半透明纸 + 底边细线
struct PetitHeaderBackground: View {
    var body: some View {
        PetitStyle.headerBg
            .overlay(alignment: .bottom) {
                Rectangle().fill(PetitStyle.headerBorder).frame(height: 1)
            }
    }
}

/// AI 气泡左边那枚 ✧ 圆（html .star）
struct PetitStar: View {
    var body: some View {
        Text("✧")
            .font(.system(size: 18))
            .foregroundStyle(PetitStyle.starFg)
            .frame(width: PetitStyle.starSize, height: PetitStyle.starSize)
            .background(Circle().fill(PetitStyle.starBg))
            .overlay(Circle().stroke(PetitStyle.starBorder, lineWidth: 1))
    }
}

/// 眉题行（替换分隔行）
struct PetitEyebrowRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: PetitStyle.eyebrowFontSize))
            .tracking(PetitStyle.eyebrowTracking)
            .foregroundStyle(PetitStyle.eyebrow)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, PetitStyle.eyebrowBottom)
    }
}

/// "sealed with a little love ♡"
struct PetitSealRow: View {
    var body: some View {
        Text("sealed with a little love ♡")
            .font(PetitStyle.italic(PetitStyle.sealFontSize))
            .foregroundStyle(PetitStyle.seal)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
    }
}

/// 气泡外观：纸色/粉色 + 细边 + 软阴影（html .chat-bubble / .user）
struct PetitBubbleChrome: ViewModifier {
    let isUser: Bool
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: PetitStyle.bubbleRadius, style: .continuous)
                    .fill(isUser ? PetitStyle.userFill : PetitStyle.paper)
                    .shadow(color: PetitStyle.shadow, radius: 9, x: 0, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PetitStyle.bubbleRadius, style: .continuous)
                    .stroke(PetitStyle.paperBorder, lineWidth: 1)
            )
    }
}

/// 只在皮开着时给气泡加纸色/细边/阴影，关着时原样返回
struct PetitBubbleChromeIfActive: ViewModifier {
    let isUser: Bool
    func body(content: Content) -> some View {
        if PetitStyle.active {
            content.modifier(PetitBubbleChrome(isUser: isUser))
        } else {
            content
        }
    }
}

/// 输入框：皮开着时是 70 高的圆胶囊（html .input），关着时回 243 的 roundedBorder
struct PetitInputField: ViewModifier {
    func body(content: Content) -> some View {
        if PetitStyle.active {
            content
                .textFieldStyle(.plain)
                .padding(.leading, PetitStyle.inputLeading)
                .padding(.vertical, 6)
                .frame(minHeight: PetitStyle.inputHeight)
                .background(
                    RoundedRectangle(cornerRadius: PetitStyle.inputRadius, style: .continuous)
                        .fill(PetitStyle.inputBg)
                        .shadow(color: PetitStyle.inputShadow, radius: 14, x: 0, y: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PetitStyle.inputRadius, style: .continuous)
                        .stroke(PetitStyle.inputBorder, lineWidth: 1)
                )
        } else {
            content
                .padding(.leading, 6)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// 发送键：皮开着时是 47 的圆（html .send）
struct PetitSendButton: ViewModifier {
    func body(content: Content) -> some View {
        if PetitStyle.active {
            content
                .frame(width: PetitStyle.sendSize, height: PetitStyle.sendSize)
                .background(Circle().fill(PetitStyle.sendBg))
        } else {
            content
        }
    }
}
