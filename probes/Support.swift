import Cocoa

//  共享探针基础设施（不依赖 AnnotationView，可被任何探针链接）
//
//  约定：每个探针用 @main 入口，调用 Probe.finish() 作为退出码。
//  输出格式固定为  [PASS]/[FAIL]/[INFO] <报告编号> <断言> — <实测值>
//  便于 run_all.sh 聚合成一张表。

enum Probe {
    private(set) static var pass = 0
    private(set) static var fail = 0
    private(set) static var info = 0

    /// 断言成立
    static func ok(_ id: String, _ claim: String, _ observed: String) {
        pass += 1
        print("[PASS] \(id)  \(claim)  — \(observed)")
    }

    /// 断言不成立（即缺陷复现）
    static func bug(_ id: String, _ claim: String, _ observed: String, expect: String) {
        fail += 1
        print("[FAIL] \(id)  \(claim)")
        print("         实测: \(observed)")
        print("         应为: \(expect)")
    }

    /// 仅陈述事实，不作判定（用于随会话状态变化的量）
    static func note(_ id: String, _ msg: String) {
        info += 1
        print("[INFO] \(id)  \(msg)")
    }

    static func section(_ title: String) {
        print("\n──── \(title) ────")
    }

    static func finish(_ title: String) -> Never {
        print("\n========== \(title): PASS=\(pass)  BUG=\(fail)  INFO=\(info) ==========")
        exit(fail == 0 ? 0 : 1)
    }
}

// MARK: - 图像工具

/// 读取合成图中某个 AppKit 点（左下角原点）的亮度 0...1
func luminance(_ image: NSImage, at point: CGPoint) -> CGFloat {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return -1 }
    let scaleX = CGFloat(rep.pixelsWide) / max(image.size.width, 1)
    let scaleY = CGFloat(rep.pixelsHigh) / max(image.size.height, 1)
    let px = Int(point.x * scaleX)
    let py = Int((image.size.height - point.y - 0.5) * scaleY)
    guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
          let c = rep.colorAt(x: px, y: py) else { return -1 }
    return (c.redComponent + c.greenComponent + c.blueComponent) / CGFloat(3)
}

/// 图像内容哈希（用于"两次渲染是否完全一致"的回归判定）
func imageHash(_ image: NSImage) -> UInt64 {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.bitmapData else { return 0 }
    var h: UInt64 = 1469598103934665603
    let n = rep.bytesPerRow * rep.pixelsHigh
    var i = 0
    while i < n { h = (h ^ UInt64(data[i])) &* 1099511628211; i += 7 }
    return h
}

/// 生成纯白画布
func blankCanvas(_ width: CGFloat, _ height: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    return image
}

/// 导出 PNG 的像素尺寸（用于验证导出分辨率）
func pngPixelSize(_ image: NSImage) -> (Int, Int)? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return (rep.pixelsWide, rep.pixelsHigh)
}

/// 把 NSImage 落盘为 PNG，返回像素尺寸（走与 App 保存路径完全相同的链路）
func exportPNG(_ image: NSImage, to url: URL) -> (Int, Int)? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
    try? png.write(to: url)
    return (bitmap.pixelsWide, bitmap.pixelsHigh)
}

// MARK: - 屏幕工具

/// AppKit 全局坐标 → Quartz（左上角原点，锚定主显示器）坐标。
/// 依据 CGWindow.h: "bounds … origin at the upper-left corner of the main display"
func primaryDisplayHeight() -> CGFloat {
    // "主显示器" = 菜单栏所在屏 = frame.origin == .zero 的那块
    NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
        ?? CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
}

/// App 代码里用的翻转锚点（ScreenCapture.swift:35）
func appFlipAnchorHeight() -> CGFloat {
    NSScreen.main?.frame.height ?? 0
}

func screenDesc(_ s: NSScreen?) -> String {
    guard let s = s else { return "nil" }
    return String(format: "%.0fx%.0f@(%.0f,%.0f) scale=%.1f",
                  s.frame.width, s.frame.height, s.frame.minX, s.frame.minY, s.backingScaleFactor)
}

/// 打开一个 NSApplication（探针进程需要它才能构造 NSEvent / NSWindow）
func bootstrapApp(policy: NSApplication.ActivationPolicy = .accessory) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(policy)
}
