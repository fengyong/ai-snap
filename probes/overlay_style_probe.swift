import Cocoa

// 覆盖层窗口的外观约束（链接真实的 Sources/OverlayWindowStyle.swift）。
//
// 背景：用户报告「启动截图后屏幕短暂黑屏」。
// 成因是覆盖层窗口当时是 `isOpaque = true` + `.black` —— 而窗口的 backgroundColor
// 由 WindowServer 在 contentView 绘制**之前**填充，所以「窗口已上屏、冻结帧还没画好」
// 那段空隙就是全屏纯黑。全屏冻帧是 22–56 MB 的一位图，首帧绘制 12 ms（14 寸内屏实测），
// 加首次上传与合成，黑闪足够被眼睛抓住。
//
// 这个探针钉住的是「那段空隙里屏幕上是什么颜色」——正是黑屏的直接成因。

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
    else { fail += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
}

func makeWindow() -> NSWindow {
    NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
             styleMask: .borderless, backing: .buffered, defer: false)
}

/// 模拟 WindowServer 在内容绘制之前填的那一层，读回填充结果。
/// 这就是「内容还没到」时用户实际看到的颜色。
func backdropFill(of window: NSWindow) -> NSColor {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    window.backgroundColor.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.colorAt(x: 1, y: 1)!
}

print("=== 1. apply() 之后的窗口属性 ===\n")
do {
    let w = makeWindow()
    OverlayWindowStyle.apply(to: w)

    check("不是不透明（isOpaque = false）", w.isOpaque == false)
    check("背景为完全透明（alpha = 0）",
          w.backgroundColor.alphaComponent == 0,
          "alpha = \(w.backgroundColor.alphaComponent)")
    check("无阴影", w.hasShadow == false)
    check("层级高于菜单栏（盖住菜单栏）",
          w.level.rawValue > NSWindow.Level.mainMenu.rawValue,
          "level = \(w.level.rawValue)，mainMenu = \(NSWindow.Level.mainMenu.rawValue)")
}

print("\n=== 2. 内容未到时的空隙里，屏幕是什么颜色（黑屏的直接成因）===\n")
do {
    // 修复后
    let fixed = makeWindow()
    OverlayWindowStyle.apply(to: fixed)
    let after = backdropFill(of: fixed)
    check("修复后：空隙里是**透明**（透出下方真实屏幕）",
          after.alphaComponent == 0,
          String(format: "alpha %.2f", after.alphaComponent))

    // 修复前（对照，不要改回去）
    let before = makeWindow()
    before.isOpaque = true
    before.backgroundColor = .black
    let black = backdropFill(of: before)
    check("对照：修复前是**不透明纯黑** —— 这正是用户看到的那一下",
          black.alphaComponent == 1 && black.redComponent == 0
          && black.greenComponent == 0 && black.blueComponent == 0,
          String(format: "alpha %.2f rgb %.2f %.2f %.2f",
                 black.alphaComponent, black.redComponent,
                 black.greenComponent, black.blueComponent))

    check("两者确实不同（这条断言存在的意义就是防止改回去）",
          after.alphaComponent != black.alphaComponent)
}

print("\n=== 3. 已排除的方案：orderFront 之前先画好 ===\n")
do {
    // 曾想用「上屏前同步绘制首帧」把空隙填掉。实测行不通：
    // 未上屏的窗口没有 window device，display / displayIfNeeded 都是 no-op。
    // 这里把这个结论固化下来，免得日后有人再试一遍。
    final class CountingView: NSView {
        var drawCount = 0
        override func draw(_ dirtyRect: NSRect) { drawCount += 1 }
    }

    let w = makeWindow()
    let v = CountingView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    w.contentView = v

    check("新建窗口的视图确实是待绘制的", v.needsDisplay)
    v.displayIfNeeded()
    check("未上屏时 displayIfNeeded() 不绘制（no-op）", v.drawCount == 0,
          "drawCount = \(v.drawCount)")
    v.display()
    check("未上屏时 display() 也不绘制（no-op）", v.drawCount == 0,
          "drawCount = \(v.drawCount)")
    print("""
          → 所以修复只能从「空隙里显示什么」入手（改成透明），
            而不是「把空隙填掉」（提前绘制做不到）。
            首帧绘制仍然保留在 orderFront **之后**（那时才有 window device）。
    """)
}

print("=== 通过 \(pass)，失败 \(fail) ===")
exit(fail == 0 ? 0 : 1)
