//
//  Theme.swift
//  品牌配色与卡片样式。
//
//  设计取向：**跟随系统明暗 + 青紫强调**。
//     · 底色、卡片、键格都用动态色（NSColor 的 appearance 回调），
//       系统切浅色/深色时自动换一套，不用在视图里到处读 @Environment(\.colorScheme)
//     · 强调色是一条青 → 紫的渐变，用在标题图标、选中键、主按钮、状态环上
//     · 状态色也走品牌色系：已连接 = 青绿，进行中 = 紫，出错 = 珊瑚红，
//       和系统那套绿/橙/红区分开，整屏看着是一家人
//
//  为什么不用 Asset Catalog：这个项目是 `swiftc Sources/*.swift` 直接编出来的，
//  没有 Xcode 工程，颜色只能写在代码里。动态色正好也是纯代码能做的。
//

import AppKit
import SwiftUI

enum Palette {

    // MARK: - 动态色基建

    /// 浅色 / 深色两套值打包成一个动态 NSColor，再由系统按当前外观挑。
    /// 判定用 `bestMatch`，能覆盖 aqua / darkAqua 以及高对比度变体。
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// 0xRRGGBB → NSColor（sRGB）。写十六进制比写 0.18/0.90/1.0 好读得多
    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    /// 黑 / 白按透明度叠出来的“无色”，用于描边和底色微调
    private static func ink(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha)
    }
    private static func paper(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
    }

    // MARK: - 品牌色

    /// 主强调色：青。浅色下压深一档，深色下提亮，保证两种底色上都有足够对比
    static let brand = dyn(hex(0x0E8CA6), hex(0x3BE0FF))
    /// 渐变的另一端：紫
    static let brandAlt = dyn(hex(0x6C5CE7), hex(0xB18CFF))

    /// 青 → 紫。选中键、主按钮、进度条、标题下划线都用它
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brand, brandAlt],
                       startPoint: .leading, endPoint: .trailing)
    }

    /// 斜向版本，给方块（键格、BIOS 小方块）用
    static var brandGradientTL: LinearGradient {
        LinearGradient(colors: [brand, brandAlt],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - 状态色

    /// 已连接 / 授权通过：青绿
    static let ok    = dyn(hex(0x0F9D74), hex(0x3BE0A8))
    /// 进行中（扫描、连接、捕获）：紫，和品牌渐变的第二段同族
    static let busy  = dyn(hex(0x7C5CF0), hex(0xA98BFF))
    /// 需要注意但不是错误（未授权、按住左键锁）：琥珀
    static let warn  = dyn(hex(0xB9770A), hex(0xFFC15E))
    /// 出错 / 破坏性操作：珊瑚红，比系统红柔和
    static let danger = dyn(hex(0xD93F45), hex(0xFF7B7B))

    // MARK: - 表面

    /// 窗口底色。比纯白/纯黑都偏冷一档，卡片压在上面才有层次
    static let canvas   = dyn(hex(0xECEFF7), hex(0x0D0F14))
    /// 卡片渐变的上沿 / 下沿（深色下是「上亮下暗」，让卡片有一点体积感）
    static let cardTop  = dyn(hex(0xFFFFFF), hex(0x1C2029))
    static let cardBottom = dyn(hex(0xFAFBFE), hex(0x171A22))
    /// 卡片描边：浅色靠极淡的黑线勾边，深色靠极淡的白线
    static let cardStroke = dyn(ink(0.055), paper(0.075))
    /// 卡片投影
    static let cardShadow = dyn(ink(0.075), ink(0.45))

    /// 键格 / 次级控件的底
    static let keyFill   = dyn(hex(0xF2F4FA), hex(0x232834))
    static let keyStroke = dyn(ink(0.09), paper(0.06))

    /// 凹槽：鼠标拖拽区、日志面板、进度条槽。
    /// 两个主题下都比 canvas 再暗一档——「凹」和「凸」要能一眼分开，
    /// 否则深色下日志条会和窗口底连成一片。
    static let well      = dyn(hex(0xE6EAF3), hex(0x080A0E))
    static let wellStroke = dyn(ink(0.055), paper(0.05))

    /// 标题文字：比系统 primary 稍带一点冷色，跟青紫调子一致
    static let title = dyn(hex(0x1B2130), hex(0xE9EDF6))

    /// 压在品牌色块上的文字色。
    /// 浅色主题的品牌色偏深（#0E8CA6 / #6C5CE7），配白字；
    /// 深色主题的品牌色是亮青亮紫，白字就糊了，得反过来用近黑的冷色。
    static let onBrand = dyn(paper(1), hex(0x0A0E14))

    /// **按钮专用**的强调色，比 brand 深一档。
    ///
    /// 为什么不直接用 brand：`borderedProminent` 的前景色由系统按底色算，
    /// 在深色模式下 brand 是 #3BE0FF 这种很亮的青，系统仍然给白字，
    /// 白字压亮青几乎看不清。所以按钮这一档单独压暗，两个主题都保证白字可读；
    /// 装饰性的青（标题图标、选中键、进度条）继续用亮的那支。
    static let brandButton = dyn(hex(0x0E8CA6), hex(0x1A8FA8))
    /// 破坏性按钮（停止、断开）同理：深色下不能给亮红配白字
    static let dangerButton = dyn(hex(0xD93F45), hex(0xC03A40))
    /// 警告按钮（按住左键锁）：琥珀色本身够深，只在深色下压一点
    static let warnButton = dyn(hex(0xB9770A), hex(0xC98A1E))

    // MARK: - 卡片右上角的品牌微光

    /// 极淡的青紫斜向渐变，铺在卡片最上层（不吃事件）。
    /// 浓度刻意压得很低（0.10 → 0），目的是让卡片“有点颜色”，
    /// 而不是一眼看出「这是一块渐变」。
    static func cardGlow(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [brand.opacity(0.10), brandAlt.opacity(0.045), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
    }
}

// MARK: - 统一的卡片底

/// 卡片外观。`Card` 和「本机键盘转发」那条手写横条共用，
/// 免得两处各写一份、改配色时漏一个。
struct CardSurface: ViewModifier {
    var radius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Palette.cardTop, Palette.cardBottom],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    // 投影挂在形状上而不是视图上：这样圆角外不会多一圈方影
                    .shadow(color: Palette.cardShadow, radius: 9, x: 0, y: 3)
            )
            .overlay(Palette.cardGlow(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(CardSurface(radius: cornerRadius))
    }
}

// MARK: - 分段控件

/// 自己画的两段式控件，用来替代 `Picker(.segmented)`。
///
/// 为什么不用系统控件：macOS 的 `NSSegmentedControl` 选中块颜色跟的是**系统强调色**，
/// SwiftUI 的 `.tint()` 对它不生效，于是整屏青紫里突然冒出一块系统蓝。
/// 这个版本把选中态换成品牌渐变，两个主题下都跟周围的按钮、图标同一套颜色。
struct BrandSegmented<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    /// 每段宽度。给死宽度而不是让它按文字自适应，是为了两段等宽、整体宽度可预测
    /// （顶栏那个槽位原来就是 116pt，2×56+4 正好对上）
    var segmentWidth: CGFloat = 56

    private var totalWidth: CGFloat { CGFloat(options.count) * segmentWidth + 4 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, item in
                let on = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.label)
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.onBrand : Palette.title.opacity(0.78))
                        .lineLimit(1)
                        .frame(width: segmentWidth, height: 18)
                        // 整段可点，不只是文字那几个像素
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Palette.brandGradientTL)
                    }
                }
            }
        }
        .frame(width: totalWidth)
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.keyFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.keyStroke)
        )
    }
}

// MARK: - 分隔线

/// 青 → 紫的细线，替换系统 Divider：一条线就把整屏串起来了
struct GradientRule: View {
    var height: CGFloat = 1
    var opacity: Double = 0.5

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Palette.brand.opacity(opacity),
                             Palette.brandAlt.opacity(opacity * 0.7),
                             Palette.cardStroke],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(height: height)
            .allowsHitTesting(false)
    }
}
