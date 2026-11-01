//
//  make_icon.swift
//  把一张普通图片做成 macOS 风格的 App 图标素材（.iconset 目录）
//
//  为什么不用 sips 直接缩：sips 只会等比缩放，做不出 macOS 的
//  圆角方形（squircle）和四周留白，套到 Dock 里会是一块方方正正的图。
//  这里用 CoreGraphics 把图裁成正方形、圆角裁切、居中留白，
//  再按 iconset 要求的 10 个尺寸逐张渲染。
//
//  用法： swift tools/make_icon.swift <源图> <输出.iconset 目录>
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("错误：" + message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("用法： swift make_icon.swift <源图.png> <输出目录.iconset>")
}

let srcURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let source = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("读不到图片：\(srcURL.path)")
}

/// iconset 要求的文件名与像素尺寸
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

/// 按 macOS 官方图标的比例渲染一张：四周留白约 9.8%，圆角半径约内容的 22.4%
func render(_ image: CGImage, pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    guard let ctx = CGContext(data: nil,
                              width: pixels,
                              height: pixels,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.interpolationQuality = .high

    let inset = (size * 0.098).rounded()
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 圆角内先铺白底：源图没有 alpha 通道，缩放边缘容易出现灰边
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(rect)

    // 等比放大到铺满内容区并居中裁切（源图不是正方形时取中间一块）
    let iw = CGFloat(image.width)
    let ih = CGFloat(image.height)
    let scale = max(rect.width / iw, rect.height / ih)
    let dw = iw * scale
    let dh = ih * scale
    ctx.draw(image, in: CGRect(x: rect.midX - dw / 2,
                               y: rect.midY - dh / 2,
                               width: dw,
                               height: dh))
    ctx.restoreGState()

    // 描一道很淡的边，小尺寸下轮廓更清楚
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10))
    ctx.setLineWidth(max(1, size * 0.005))
    ctx.strokePath()

    return ctx.makeImage()
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (name, pixels) in variants {
    guard let scaled = render(image, pixels: pixels) else {
        fail("渲染 \(pixels)px 失败")
    }
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("无法写出 \(name)")
    }
    CGImageDestinationAddImage(dest, scaled, nil)
    guard CGImageDestinationFinalize(dest) else { fail("无法写出 \(name)") }
}

print("已生成 \(variants.count) 张图标 → \(outDir.path)")
