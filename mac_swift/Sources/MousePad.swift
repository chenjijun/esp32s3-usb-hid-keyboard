//
//  MousePad.swift
//  鼠标输入控件：一块「按住拖动 = 移指针」的区域，加一个只报告按下/松开的透明层。
//
//  都用 SwiftUI 的 DragGesture(minimumDistance: 0) 实现，不用 NSViewRepresentable，
//  理由：这块界面在 ScrollView 里，手势走同一套事件系统最稳；
//  而 minimumDistance: 0 是关键——默认手势要移动几个像素才「开始」，
//  那样单击（按下立刻松开）根本不会触发。
//
//  状态为什么不放 @State：本项目的编译环境里 @State 是宏（SwiftUIMacros），
//  裸 swiftc 编不过。所以可变状态放在引用类型里（PadTracker），
//  闭包捕获的是同一个对象，视图重建也不会丢。
//

import SwiftUI

/// 拖拽过程中的采样点。放引用类型里，手势闭包跨多次回调都能读到最新位置。
final class PadTracker {
    private var last: CGPoint?

    /// 相对上一次的位移；第一次调用只记位置，返回 nil
    func delta(to point: CGPoint) -> (Double, Double)? {
        defer { last = point }
        guard let previous = last else { return nil }
        // SwiftUI 的坐标 y 已经朝下，和主机屏幕一致，不必取反
        return (Double(point.x - previous.x), Double(point.y - previous.y))
    }

    func end() { last = nil }
}

/// 相对位移捕获区。按住拖动，每次位移回调一次（单位 pt）。
struct MousePadView: View {
    let tracker: PadTracker
    var onDelta: (Double, Double) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let delta = tracker.delta(to: value.location) {
                            onDelta(delta.0, delta.1)
                        }
                    }
                    .onEnded { _ in tracker.end() }
            )
    }
}

/// 一块透明区域，只报告「按下 / 松开」。
/// 鼠标三键要用它：SwiftUI 的 Button 只有 click 这一下，
/// 拆不出「按住不放 → 松开」两段，而右键菜单、拖拽都靠这两段。
/// 这里不做去重，交给调用方按「当前是否已经按下」判断（重复的 down 会被忽略）。
struct PressCatcher: View {
    var onPress: () -> Void
    var onRelease: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}
