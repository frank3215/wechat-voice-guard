// 生成应用图标：绿色渐变圆角方块 + 白色「续」字（与悬浮球同一套视觉语言）
// 用法：swiftc -O tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon assets/AppIcon.iconset
//      然后 iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
// 之所以自己画：这个仓库不想引入任何设计素材依赖，图标必须能从源码一键重建。

import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func renderPNG(size s: CGFloat) -> Data? {
    guard let img = NSImage(size: NSSize(width: s, height: s)) as NSImage? else { return nil }
    img.lockFocus()

    // 背景：圆角方块 + 上下渐变（留出系统图标惯用的边距）
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = s * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    if let grad = NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.80, blue: 0.50, alpha: 1.0),
                             ending:   NSColor(srgbRed: 0.08, green: 0.55, blue: 0.33, alpha: 1.0)) {
        grad.draw(in: path, angle: -90)
    } else {
        NSColor(srgbRed: 0.16, green: 0.72, blue: 0.42, alpha: 1.0).setFill()
        path.fill()
    }

    // 顶部高光边，避免在深色 Dock 上显得发闷
    NSColor.white.withAlphaComponent(0.28).setStroke()
    path.lineWidth = max(1.0, s * 0.014)
    path.stroke()

    // 中间的字
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.46, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    let text = NSAttributedString(string: "续", attributes: attrs)
    let ts = text.size()
    text.draw(at: NSPoint(x: (s - ts.width) / 2.0, y: (s - ts.height) / 2.0))

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return nil }
    return data
}

// iconutil 要求的文件名（1x / 2x 成对）
let wanted: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var made = 0
for (name, px) in wanted {
    guard let data = renderPNG(size: px) else {
        FileHandle.standardError.write("渲染失败: \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    do {
        try data.write(to: url)
        made += 1
    } catch {
        FileHandle.standardError.write("写入失败 \(name): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
print("已渲染 \(made) 个尺寸 -> \(outDir)")
