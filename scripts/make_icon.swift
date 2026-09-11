import Cocoa

// 生成应用图标主图（1024×1024 PNG）。
//
// 为什么用代码画、而不是丢一个来路不明的二进制资源进仓库：
// 图标能随代码一起进版本库、可以重生成、改配色只改几个常量，
// 也不会出现"这张图是谁做的、能不能改"的悬案。
//
// 用法：swift scripts/make_icon.swift <输出路径>

let size: CGFloat = 1024
/// macOS 图标的圆角方框在 1024 画布里占 824、四周留白 —— 这是系统的视觉惯例，
/// 留白少了图标在 Dock / 访达里会显得比邻居大一圈。
let box: CGFloat = 824
let cornerRadius: CGFloat = 185

// 配色（与应用的蓝色系一致；中心那点红对应默认标注色）
let topColor = CGColor(red: 0.36, green: 0.55, blue: 0.98, alpha: 1)
let bottomColor = CGColor(red: 0.10, green: 0.25, blue: 0.76, alpha: 1)
let markColor = CGColor(red: 1.0, green: 0.29, blue: 0.24, alpha: 1)

let ctx = CGContext(data: nil,
                    width: Int(size), height: Int(size),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 画布坐标 y 向上；下面所有"上/下"都按视觉说，代码里换算成 y。

let inset = (size - box) / 2
let squircle = CGPath(roundedRect: CGRect(x: inset, y: inset, width: box, height: box),
                      cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                      transform: nil)

// 1. 背景：竖向渐变
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [topColor, bottomColor] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: 0, y: 0),
                       options: [])
// 顶部一层很淡的高光，避免纯平涂看起来发闷
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
                                CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: 0, y: size * 0.55),
                       options: [])
ctx.restoreGState()

// 2. 取景框四角
//
// 只画左下角一个「带圆角的 L」，其余三个用镜像变换复制出来 ——
// 手写四份坐标是最容易把某个角画歪的做法，而且歪了不容易一眼看出。
func cornerBracket(arm: CGFloat, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: arm, y: 0))
    path.addLine(to: CGPoint(x: radius, y: 0))
    // 圆心在 (r, r)、从 -90° 顺时针到 180°：这一段弧朝着角点方向凸，
    // 得到的才是"向内收圆"的角（反过来就成一个外翻的圆弧了）
    path.addArc(center: CGPoint(x: radius, y: radius), radius: radius,
                startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
    path.addLine(to: CGPoint(x: 0, y: arm))
    return path
}

let bracketInset: CGFloat = 212
let bracket = cornerBracket(arm: 176, radius: 44)
let brackets = CGMutablePath()
for (sx, sy) in [(CGFloat(1), CGFloat(1)), (-1, 1), (1, -1), (-1, -1)] {
    var transform = CGAffineTransform(scaleX: sx, y: sy)
    transform = transform.concatenating(
        CGAffineTransform(translationX: sx > 0 ? bracketInset : size - bracketInset,
                          y: sy > 0 ? bracketInset : size - bracketInset))
    if let mirrored = bracket.copy(using: &transform) {
        brackets.addPath(mirrored)
    }
}

ctx.saveGState()
ctx.addPath(brackets)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// 3. 中心标记点（对应"被标注的那个位置"）
let dotRadius: CGFloat = 78
ctx.saveGState()
ctx.setFillColor(markColor)
ctx.fillEllipse(in: CGRect(x: size / 2 - dotRadius, y: size / 2 - dotRadius,
                           width: dotRadius * 2, height: dotRadius * 2))
ctx.restoreGState()

// 4. 输出
guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("渲染失败\n".utf8))
    exit(1)
}
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Assets/AppIcon-1024.png"
let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
do {
    try data.write(to: url)
    print("已生成 \(outputPath)（\(Int(size))×\(Int(size))）")
} catch {
    FileHandle.standardError.write(Data("写入失败：\(error)\n".utf8))
    exit(1)
}
