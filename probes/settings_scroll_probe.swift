// 设置窗口滚动容器探针（E06，2026-11-09）。
//
// 场景：设置内容按 fitting 高度撑窗，而设置项只增不减。实测（2026-11-09，
// 本机可视高度 1050）：**空忽略列表的内容就有 1162pt**，超过钳制上限 970pt
// —— 即 E06 不只影响「列表很长」的极端场景，在这块屏上默认状态下底部按钮
// 就可能够不着。修法：内容包进 NSScrollView，窗口高度钳到屏幕可视区。
//
// 钉住的事实（全部可离屏观测）：
//   §1 长列表：窗口**内容**高度 = 钳制上限；document 高于视口（可滚）；
//      documentView 已翻转（初始停在顶部而不是底部）
//   §2 内容随数据收缩：空列表的 document 高度 < 长列表（行为随内容变化）；
//      空列表下同样钳制 + 可滚（本机基线内容就超高，这是目标行为）
//   §3 关窗后可复用：设置窗口是刻意常驻的（AppDelegate 缓存控制器、再次
//      present() 显示**同一个**窗口）—— 与一次性窗口的「用完即释」约定相反，
//      这里钉的是复用语义本身，防止将来误改成一次性窗口
//
//      run_probe settings_scroll_probe Sources/Models.swift Sources/Capture/ScreenGeometry.swift \
//          Sources/Preferences.swift Sources/HotkeyManager.swift Sources/LaunchAtLogin.swift \
//          Sources/History/CaptureHistory.swift Sources/SettingsWindow.swift
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

_ = NSApplication.shared

func openSettings() -> (SettingsWindowController, NSWindow, NSScrollView) {
    let controller = SettingsWindowController()
    controller.present()
    let window = controller.window!
    window.layoutIfNeeded()   // 无 runloop 的探针里，几何断言前先冲一次布局
    let scroll = window.contentView as! NSScrollView
    scroll.contentView.layoutSubtreeIfNeeded()
    return (controller, window, scroll)
}

/// 窗口内容高度（frame 减标题栏）。钳制作用在内容上，不是 frame 上。
func contentHeight(_ window: NSWindow) -> CGFloat {
    window.contentRect(forFrameRect: window.frame).height
}

let originalIgnored = Preferences.shared.ignoredBundleIdentifiers
defer { Preferences.shared.ignoredBundleIdentifiers = originalIgnored }

print("=== 1. 长忽略列表（40 条）：钳高 + 可滚 + 翻转 ===\n")
var longDocH: CGFloat = 0
do {
    Preferences.shared.ignoredBundleIdentifiers = (0..<40).map { "com.probe.ignored.app\($0)" }
    let (_, window, scroll) = openSettings()

    let visibleH = NSScreen.main?.visibleFrame.height ?? 900
    let clampMax = visibleH - 80
    let contentH = contentHeight(window)
    check("窗口内容高度 = 钳制上限（内容确实装不下）",
          abs(contentH - clampMax) <= 2,
          "内容 \(Int(contentH)) vs 上限 \(Int(clampMax))")
    check("有竖向滚动条", scroll.hasVerticalScroller)

    let document = scroll.documentView!
    let documentH = document.fittingSize.height
    longDocH = documentH
    let viewportH = scroll.contentView.frame.height
    check("document 高于视口（内容滚得到）",
          documentH > viewportH + 50,
          "document \(Int(documentH)) > 视口 \(Int(viewportH))")
    // documentView 必须翻转：不翻转的 documentView 从左下角铺开，初始可见的
    // 是**底部**（恢复默认那一头），用户得先滚一下才看到顶部的快捷键区
    check("documentView 已翻转（初始停在顶部）",
          document.isFlipped,
          "isFlipped=\(document.isFlipped)")

    window.close()
    check("关窗后窗口仍被持有（设置窗刻意常驻复用，与一次性窗相反）",
          NSApp.windows.contains { $0 === window },
          "已被释放——那才是问题")
}

do {
    // 复用语义：close 之后再 present，显示的必须是同一个窗口
    let controller = SettingsWindowController()
    controller.present()
    let first = controller.window!
    first.close()
    controller.present()
    check("再次 present 显示同一个窗口（控制器缓存生效）",
          controller.window === first,
          "变成了新窗口 = 一次性窗口")
    check("第二次 present 后窗口可见",
          first.isVisible,
          "不可见")
    first.close()
}

print("\n=== 2. 空忽略列表：内容收缩、仍钳高可滚（本机基线内容就超高）===\n")
do {
    Preferences.shared.ignoredBundleIdentifiers = []
    let (_, window, scroll) = openSettings()

    let documentH = scroll.documentView!.fittingSize.height
    let viewportH = scroll.contentView.frame.height
    let contentH = contentHeight(window)
    let clampMax = (NSScreen.main?.visibleFrame.height ?? 900) - 80
    check("空列表的 document 比长列表矮（内容随数据收缩）",
          documentH < longDocH - 200,
          "空 \(Int(documentH)) < 长 \(Int(longDocH)) - 200")
    check("空列表内容也超过钳制上限（E06 本机实存）",
          documentH > clampMax,
          "基线内容 \(Int(documentH)) > 上限 \(Int(clampMax))")
    check("窗口内容高度仍 = 钳制上限",
          abs(contentH - clampMax) <= 2,
          "内容 \(Int(contentH)) vs 上限 \(Int(clampMax))")
    check("可滚（底部恢复默认经滚动可达）",
          documentH > viewportH + 2,
          "document \(Int(documentH)) > 视口 \(Int(viewportH))")

    window.close()
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
