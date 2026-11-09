// 标注窗口 / OCR 结果面板的生命周期探针 —— 判定「关闭后是否真的释放」。
//
// 背景：pin_lifetime_probe 钉死了「isReleasedWhenClosed = false 时 NSApp.windows
// 在 close() 后仍强引用窗口」这条泄漏链。同类问题全库排查（2026-11-09）发现
// 另外两处同根：
//   · AnnotationWindow —— **每次截图**净增一个窗口对象，连着整张画布、底图与
//     全部标注对象（比贴图泄漏更重）；
//   · OCRResultWindow —— 每次识别净增一个面板。
//
// AnnotationWindow 的修复多一个前提：setupMainMenu 的菜单项（撤销/重做/复制/
// 保存/帮助）target 是本窗口，窗口释放后菜单若还在就是悬挂 target —— 所以
// close() 里必须同时清掉 NSApp.mainMenu（下一个标注窗打开时会重建）。
//
// 判据沿用 pin_lifetime_probe 的：**NSApp.windows 计数**（不受 ARC 生命周期
// 延长与 autorelease pool 干扰的唯一无歧义信号）。
//
//      run_probe window_lifetime_probe   "${ALL_SOURCES[@]}"
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

func blankImage(_ w: CGFloat, _ h: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    img.unlockFocus()
    return img
}

func makeAnnotationWindow() -> AnnotationWindow {
    AnnotationWindow(image: blankImage(800, 500),
                     anchor: nil,
                     pixelSize: CGSize(width: 800, height: 500))
}

print("=== 1. AnnotationWindow：开 → 关，NSApp.windows 回到 baseline ===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    let window = makeAnnotationWindow()
    window.makeKeyAndOrderFront(nil)
    check("开窗后主菜单已建立（菜单项 target = 本窗口）",
          NSApp.mainMenu != nil && !NSApp.mainMenu!.items.isEmpty,
          "mainMenu=\(NSApp.mainMenu.map { "\($0.items.count) 项" } ?? "nil")")
    window.close()
    check("close 后 NSApp.windows 回到 baseline",
          NSApp.windows.count == baseline,
          "baseline=\(baseline) → \(NSApp.windows.count)")
    check("close 后主菜单一并清掉（菜单项 target 不悬挂）",
          NSApp.mainMenu == nil,
          "mainMenu=\(NSApp.mainMenu.map { "\($0.items.count) 项" } ?? "nil")")
}

print("\n=== 2. AnnotationWindow：3 次「开 → 关」不累积 ===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    for _ in 0..<3 {
        let window = makeAnnotationWindow()
        window.close()
    }
    check("3 次开关净增 0（旧实现每次 +1，连着整张画布与底图）",
          NSApp.windows.count == baseline,
          "baseline=\(baseline) → \(NSApp.windows.count)")
}

print("\n=== 3. OCRResultWindow：开 → 关，回到 baseline；再开时菜单已重建 ===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    let panel = OCRResultWindow(items: [])
    panel.makeKeyAndOrderFront(nil)
    panel.close()
    check("close 后 NSApp.windows 回到 baseline",
          NSApp.windows.count == baseline,
          "baseline=\(baseline) → \(NSApp.windows.count)")

    // 关掉面板后再开一个标注窗：菜单应被重建（保证「清菜单」没有误伤下一个会话）
    let window = makeAnnotationWindow()
    check("再开标注窗时主菜单已重建",
          NSApp.mainMenu != nil && !NSApp.mainMenu!.items.isEmpty,
          "mainMenu=\(NSApp.mainMenu.map { "\($0.items.count) 项" } ?? "nil")")
    window.close()
    check("收尾：窗口与菜单都干净",
          NSApp.windows.count == baseline && NSApp.mainMenu == nil,
          "windows=\(NSApp.windows.count) mainMenu=\(NSApp.mainMenu == nil ? "nil" : "非 nil")")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
