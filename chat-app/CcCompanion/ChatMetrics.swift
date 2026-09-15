//  ChatMetrics.swift — 聊天页气泡/行距的数值集中地（珩 2026-09-12，1.3 build 243）
//
//  数字从留灯 PWA（/var/www/companion-web/index.html）手机断点（@media max-width:520px）的 CSS 量出来，
//  冰冰觉得那套布局舒服。PWA 没定义的项用 Telegram iOS 的数。改数只改这一个文件，视图里别再散写。
//
//  PWA 量到的（手机断点）：
//    .bubble   font-size 13.5px / line-height 1.56（≈21px）/ padding 8px 13px / border-radius 14px
//              max-width min(63vw, 520px)
//    .row      margin-top 18px；.row.grouped（同方 5 分钟内成组）8px
//    .row.tail 段尾气泡外下角 2px（ai 左下 / human 右下）
//    .meta     时间戳 11px，颜色 text-faint；同方 5 分钟内成组（GROUP_GAP = 5*60e3）
//    --side-pad 16px；--avatar-size 32px（本 app 行内不画头像，只取 side-pad）
//  Telegram iOS 补的：连发缝 3pt 没用到（PWA 有 8）；行距 22 没用到（PWA 有 1.56）。

import SwiftUI
import UIKit

enum ChatMetrics {
    // MARK: 正文
    /// PWA 手机断点 .bubble font-size: 13.5px。设置里的 小/中/大 在此基础上 ∓1.5。
    static var bodyFontSize: CGFloat { PetitStyle.active ? PetitStyle.bodyFontSize : 13.5 }   // 小小世界：14（珩 2026-09-15）
    static let bodyFontStep: CGFloat = 1.5
    /// PWA line-height 1.56 → 行高 ≈ 21pt；SwiftUI 用 lineSpacing 补差值。
    static let bodyLineHeightMultiple: CGFloat = 1.56

    static func bodyFontSize(level: String) -> CGFloat {
        switch level {
        case "small": return bodyFontSize - bodyFontStep
        case "large": return bodyFontSize + bodyFontStep
        default: return bodyFontSize
        }
    }

    /// 行距补差：目标行高（字号 × 1.56）减去系统字体自身行高，不足 0 归 0。
    static func bodyLineSpacing(fontSize: CGFloat) -> CGFloat {
        if PetitStyle.active { return PetitStyle.bodyLineSpacing(fontSize: fontSize) }   // 小小世界：宋体 × 1.8
        let natural = UIFont.systemFont(ofSize: fontSize).lineHeight
        return max(0, (fontSize * bodyLineHeightMultiple).rounded() - natural)
    }

    // MARK: 气泡
    /// PWA padding: 8px 13px
    static var bubblePaddingVertical: CGFloat { PetitStyle.active ? PetitStyle.bubblePaddingVertical : 8 }
    static var bubblePaddingHorizontal: CGFloat { PetitStyle.active ? PetitStyle.bubblePaddingHorizontal : 13 }
    /// PWA --bubble-radius: clamp(14px, 2vw, 20px) → 手机 14
    static var bubbleCornerRadius: CGFloat { PetitStyle.active ? PetitStyle.bubbleRadius : 14 }
    /// PWA .row.tail：段尾外下角收成 2px 小尖
    static let bubbleTailCornerRadius: CGFloat = 2
    /// PWA max-width: min(63vw, 520px)
    static var bubbleMaxWidthFraction: CGFloat { PetitStyle.active ? PetitStyle.bubbleMaxWidthFraction : 0.63 }
    static let bubbleMaxWidthCap: CGFloat = 520

    static func bubbleMaxWidth(containerWidth: CGFloat) -> CGFloat {
        let w = containerWidth > 0 ? containerWidth : UIScreen.main.bounds.width
        return min(bubbleMaxWidthCap, (w * bubbleMaxWidthFraction).rounded())
    }

    // MARK: 行
    /// PWA --side-pad: 16px（气泡离屏幕两侧）
    static var sideInset: CGFloat { PetitStyle.active ? PetitStyle.sideInset : 16 }
    /// PWA .row margin-top: 18px（不同段之间）
    static var rowGap: CGFloat { PetitStyle.active ? PetitStyle.rowGap : 18 }
    /// PWA .row.grouped margin-top: 8px（同方 5 分钟内连发）
    static var rowGapGrouped: CGFloat { PetitStyle.active ? PetitStyle.rowGapGrouped : 8 }
    /// PWA GROUP_GAP = 5 分钟：同一方两条消息间隔 ≤ 这个数就成组（时间戳只在段尾显示、圆角只在段尾收尖）
    static let groupGapSeconds: TimeInterval = 5 * 60
    /// 列表最底下留的一点空（原 safeAreaInset 8）
    static let listBottomInset: CGFloat = 8
    /// 列表顶上留的一点空
    static let listTopInset: CGFloat = 6

    // MARK: 时间戳
    /// PWA .meta font-size: 11px
    static var timeFontSize: CGFloat { PetitStyle.active ? PetitStyle.timeFontSize : 11 }
    /// 时间行与气泡的距离
    static var timeTopGap: CGFloat { PetitStyle.active ? PetitStyle.timeTopGap : 2 }

    // MARK: 判定
    /// 两条消息是否"同一段"：同一方、都不是 task、间隔 ≤ groupGapSeconds。
    static func isGrouped(prev: ChatMessage?, cur: ChatMessage) -> Bool {
        guard let prev, prev.role == cur.role, cur.role != "task", prev.role != "task" else { return false }
        guard let a = parse(prev.ts), let b = parse(cur.ts) else { return false }
        let d = b.timeIntervalSince(a)
        return d >= 0 && d <= groupGapSeconds
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ ts: String) -> Date? {
        iso.date(from: ts) ?? isoNoFrac.date(from: ts)
    }
}
