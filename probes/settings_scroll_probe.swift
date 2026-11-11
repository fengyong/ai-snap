// 设置窗口滚动容器探针（E06，2026-11-09；2026-11-11 O2 去环境依赖）。
//
// 场景：设置内容按 fitting 高度撑窗，而设置项只增不减。实测（2026-11-09，
// 本机可视高度 1050）：**空忽略列表的内容就有 1162pt**，超过钳制上限 970pt
// —— 即 E06 不只影响「列表很长」的极端场景，在这块屏上默认状态下底部按钮
// 就可能够不着。修法：内容包进 NSScrollView，窗口高度钳到屏幕可视区。
//
// **2026-11-11（O2）**：这份探针原来断言「窗口内容高度 = 钳制上限」，
// 而钳制上限是按**本机屏幕**算的 —— 于是「内容装不装得下」这件事在不同机器上
// 结论不同：高屏机器上内容装得下，断言直接变红。红灯常态化 = 回归网失效
// （这正是 EXPECTED_FAIL 机制被用来掩盖真问题的前提被破坏）。
// 现在改成**注入固定的屏幕可视高度**：生产侧多了一个 `visibleHeightProvider`
// 注入点与纯函数 `clampMaxHeight(visibleHeight:)`，探针给定固定高度，
// 任何机器上都是同一组数字。
//
// 钉住的事实（全部可离屏观测）：
//   §0 纯函数：clampMaxHeight 的固定用例值（1440 / 1050 / 800 / 下限 320）
//   §1 长列表：注入三档固定高度 → 窗口**内容**高度 = 钳制上限；document 高于
//      视口（可滚）；documentView 已翻转（初始停在顶部而不是底部）
//   §2 空忽略列表：内容随数据收缩；钳制边界的**两侧**都要对 ——
//      上限高于内容 → 窗口 = 内容高（装得下就不钳制）；
//      上限低于内容 → 窗口 = 上限 + 可滚
//      （分界高度跟着实测内容高度走，不赌固定值：内容高度随系统字号变）
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

/// 开设置窗，并把「屏幕可视高度」**注入**为给定值。
///
/// 为什么必须注入（O2）：钳制上限 = 可视高度 − 80，而「内容装不装得下」取决于
/// 内容高度（布局决定）**与**上限（屏幕决定）的大小关系 —— 两边都读本机的话，
/// 换台机器结论就变，断言从「测行为」退化成「测这台机器的屏幕」。
/// 注入后，任何机器上都是同一组数字。
///
/// 注入点在 `present()` **之前**设：`present()` 末尾会重算一次窗口高度
/// （内容行数变了要重算），那次重算才是最终生效的那次。
func openSettings(visibleHeight: CGFloat) -> (SettingsWindowController, NSWindow, NSScrollView) {
    let controller = SettingsWindowController()
    controller.visibleHeightProvider = { visibleHeight }
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

/// 内容（document）高度 —— 钳制的另一端，由布局决定。
func documentHeight(_ scroll: NSScrollView) -> CGFloat {
    scroll.documentView!.fittingSize.height
}

let originalIgnored = Preferences.shared.ignoredBundleIdentifiers
defer { Preferences.shared.ignoredBundleIdentifiers = originalIgnored }

print("=== 0. 纯函数：clampMaxHeight 的固定用例值（不依赖本机屏幕）===\n")
do {
    check("可视高 1440 → 上限 1360",
          SettingsWindowController.clampMaxHeight(visibleHeight: 1440) == 1360,
          "\(SettingsWindowController.clampMaxHeight(visibleHeight: 1440))")
    check("可视高 1050 → 上限 970",
          SettingsWindowController.clampMaxHeight(visibleHeight: 1050) == 970,
          "\(SettingsWindowController.clampMaxHeight(visibleHeight: 1050))")
    check("可视高 800 → 上限 720",
          SettingsWindowController.clampMaxHeight(visibleHeight: 800) == 720,
          "\(SettingsWindowController.clampMaxHeight(visibleHeight: 800))")
    check("可视高 300 → 下限 320（极矮屏也不能窄到没法用）",
          SettingsWindowController.clampMaxHeight(visibleHeight: 300) == 320,
          "\(SettingsWindowController.clampMaxHeight(visibleHeight: 300))")
}

print("\n=== 1. 长忽略列表（40 条）：钳高 + 可滚 + 翻转 ===\n")
var longDocH: CGFloat = 0
do {
    Preferences.shared.ignoredBundleIdentifiers = (0..<40).map { "com.probe.ignored.app\($0)" }
    // 三档固定高度。40 条列表在任何合理系统字号下都远超 1360，
    // 所以「一定装不下」这件事不靠赌 —— 断言与本机屏幕无关。
    for visible in [800.0, 1050.0, 1440.0] {
        let (_, window, scroll) = openSettings(visibleHeight: visible)
        let clampMax = SettingsWindowController.clampMaxHeight(visibleHeight: visible)
        let contentH = contentHeight(window)
        check("可视高 \(Int(visible)) → 窗口内容高度 = 钳制上限 \(Int(clampMax))",
              abs(contentH - clampMax) <= 2,
              "内容 \(Int(contentH)) vs 上限 \(Int(clampMax))")

        let document = scroll.documentView!
        let documentH = documentHeight(scroll)
        longDocH = documentH
        let viewportH = scroll.contentView.frame.height
        // 滚动条是否**可见**的判据是内容溢不溢出视口 ——
        // `hasVerticalScroller` 对程序创建的 NSScrollView 恒为 true（两种情形都是），
        // 拿它当断言等于什么都没断言。
        check("可视高 \(Int(visible)) → 内容溢出视口（滚动条因此可见）",
              documentH > viewportH + 50,
              "document \(Int(documentH)) > 视口 \(Int(viewportH))")
        // 钳制作用在**内容**上，不是 frame 上：frame 比内容高出来的那截是标题栏。
        check("可视高 \(Int(visible)) → 钳制作用在内容上（frame − 内容 = 标题栏，不是 0）",
              (window.frame.height - contentH) > 10 && (window.frame.height - contentH) < 60,
              "差 \(Int(window.frame.height - contentH))")
        // documentView 必须翻转：不翻转的 documentView 从左下角铺开，初始可见的
        // 是**底部**（恢复默认那一头），用户得先滚一下才看到顶部的快捷键区
        check("可视高 \(Int(visible)) → documentView 已翻转（初始停在顶部）",
              document.isFlipped,
              "isFlipped=\(document.isFlipped)")

        window.close()
    }
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
    check("关窗后窗口仍被持有（设置窗刻意常驻复用，与一次性窗相反）",
          NSApp.windows.contains { $0 === first },
          "已被释放——那才是问题")
}

print("\n=== 2. 空忽略列表：内容收缩，钳制边界两侧都要对 ===\n")
do {
    Preferences.shared.ignoredBundleIdentifiers = []

    // 先用一个「高到一定装得下」的高度开窗，量出内容高度。
    // 内容高度由布局决定（随系统字号/缩放变），所以「装得下 / 装不下」的分界
    // 必须**跟着内容走**，不能用固定高度赌 —— 赌输了就是换台机器红一次。
    let (_, probeWindow, probeScroll) = openSettings(visibleHeight: 4000)
    let emptyDocH = documentHeight(probeScroll)
    check("给足够大的可视高 → 窗口高度 = 内容高度（装得下就不钳制）",
          abs(contentHeight(probeWindow) - emptyDocH) <= 2,
          "窗口 \(Int(contentHeight(probeWindow))) vs 内容 \(Int(emptyDocH))")
    probeWindow.close()

    check("空列表的 document 比长列表矮（内容随数据收缩）",
          emptyDocH < longDocH - 200,
          "空 \(Int(emptyDocH)) < 长 \(Int(longDocH)) - 200")

    // 装得下的一侧：上限高于内容 → 窗口 = 内容高，不钳制
    do {
        let (_, window, scroll) = openSettings(visibleHeight: emptyDocH + 200)
        let docH = documentHeight(scroll)
        let viewportH = scroll.contentView.frame.height
        check("上限高于内容 → 窗口高度 = 内容高度（不钳制）",
              abs(contentHeight(window) - docH) <= 2,
              "窗口 \(Int(contentHeight(window))) vs 内容 \(Int(docH))")
        check("上限高于内容 → 内容不溢出视口（装得下就不该滚）",
              docH <= viewportH + 2,
              "document \(Int(docH)) vs 视口 \(Int(viewportH))")
        window.close()
    }

    // 装不下的一侧：上限低于内容 → 窗口 = 上限 + 可滚
    do {
        let (_, window, scroll) = openSettings(visibleHeight: emptyDocH - 200)
        let docH = documentHeight(scroll)
        let viewportH = scroll.contentView.frame.height
        let clampMax = SettingsWindowController.clampMaxHeight(visibleHeight: emptyDocH - 200)
        check("上限低于内容 → 窗口内容高度 = 钳制上限",
              abs(contentHeight(window) - clampMax) <= 2,
              "内容 \(Int(contentHeight(window))) vs 上限 \(Int(clampMax))")
        check("上限低于内容 → document 高于视口（可滚到底部的恢复默认）",
              docH > viewportH + 2,
              "document \(Int(docH)) > 视口 \(Int(viewportH))")
        check("上限低于内容 → 窗口确实比内容矮（钳住了，不是没钳）",
              contentHeight(window) < docH,
              "窗口 \(Int(contentHeight(window))) < 内容 \(Int(docH))")
        window.close()
    }
}

print("\n=== 4. 钳制取「窗口所在屏」，不是 NSScreen.main ===\n")
do {
    // `NSScreen.main` 是「当前持键盘焦点的屏幕」，不是窗口所在的屏。
    // 设置窗开在副屏时用它来钳高，就会被钳到主屏的高度 —— 副屏比主屏矮时
    // 窗口掉出副屏可视区，正是 E06 要修的那个 bug 的镜像。
    //
    // 怎么验：把设置窗挪到**非主屏**上，再让内容高到必然被钳，
    // 于是「窗口有多高」直接暴露了「用的是哪块屏的高度」。
    Preferences.shared.ignoredBundleIdentifiers = (0..<40).map { "com.probe.ignored.app\($0)" }
    let (_, probeWindow, probeScroll) = openSettings(visibleHeight: 4000)
    let docH = documentHeight(probeScroll)
    probeWindow.close()

    // 目标屏：钳制上限要低于内容高度（否则窗口压根不被钳，测不出「取了哪块屏」），
    // 且必须是**非主屏**（否则与「用 NSScreen.main」不可区分）。
    let clamped = NSScreen.screens.filter {
        SettingsWindowController.clampMaxHeight(visibleHeight: $0.visibleFrame.height) < docH
    }
    if let target = clamped.first(where: { $0 != NSScreen.main }) {
        let controller = SettingsWindowController()
        let window = controller.window!
        // 挪位置必须在 present **之前** —— 已 order in 的窗口挪动后
        // window.screen 不会跟着更新（实测返回 nil，钳制就退回主屏了）。
        var f = window.frame
        f.origin = CGPoint(x: target.visibleFrame.midX - f.width / 2,
                           y: target.visibleFrame.midY - f.height / 2)
        window.setFrameOrigin(f.origin)
        controller.present()
        window.layoutIfNeeded()

        let expected = SettingsWindowController.clampMaxHeight(visibleHeight: target.visibleFrame.height)
        let mainExpected = SettingsWindowController.clampMaxHeight(
            visibleHeight: NSScreen.main?.visibleFrame.height ?? 900)
        let contentH = contentHeight(window)
        check("窗口挪到 \(target.frame) 上 → 窗口.screen 跟着走",
              window.screen?.frame == target.frame,
              "\(String(describing: window.screen?.frame))")
        check("钳制上限按**窗口所在屏**算（不是 NSScreen.main）",
              abs(contentH - expected) <= 2,
              "内容 \(Int(contentH)) vs 该屏上限 \(Int(expected))")
        check("确实没用主屏的高度（两屏上限不同时才有意义）",
              expected == mainExpected || abs(contentH - mainExpected) > 2,
              "主屏上限 \(Int(mainExpected))")
        window.close()
    } else {
        // 单屏环境下「窗口所在屏」与「主屏」本来就是同一块屏，从无从区分 ——
        // 这不是漏测，是那台机器上这条 bug 本就不成立。
        print("  ⏭️ 本机没有「非主屏且内容会被钳」的屏，跳过这一条"
              + "（单屏环境下两个取法等价，这条 bug 不成立）")
    }
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
