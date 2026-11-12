// 设置窗口布局探针（E06，2026-11-09；O2 去环境依赖；2026-11-12 改版为分类侧栏）。
//
// **改版前**：窗口高度 = 内容高度（上限为屏幕可视高 −80）。实测内容 1162pt
// （空忽略列表时）> 钳制上限 970~1042pt，于是**开窗即满屏 + 永远带滚动条** ——
// E06 只解决了「内容都够得着」，没解决「开窗就满屏」。
//
// **改版后**：窗口尺寸**固定**（640 × 520pt），与内容、与忽略列表长度都无关；
// 内容超出由内容区自己滚；左侧分类侧栏 4 组，右侧只显示当前组。
//
// 钉住的事实（全部可离屏观测）：
//   §0 纯函数：clampMaxHeight / contentHeight / resolveVisibleHeight 的固定用例值
//   §1 窗口高度固定：忽略列表 0 条与 40 条时**同高**；可视高够大时恒为 520；
//      屏特别矮时才被钳到上限（钳制作用在内容上，不是 frame 上）
//   §2 侧栏结构：4 个顶层分组都在、默认选中第一个、切换分组时只有该组可见
//   §2b「忽略的应用」独立成子面板：侧栏树 4 顶层 + 1 子项；**清单容器不在
//      快捷键组里**（快捷键页只留「计数 + 设置…」摘要行）；「设置…」点了
//      真的切到子面板；清单增删时摘要行与侧栏徽标的计数跟着变
//   §3 关窗后可复用：设置窗口是刻意常驻的（AppDelegate 缓存控制器、再次
//      present() 显示**同一个**窗口）—— 与一次性窗口的「用完即释」约定相反，
//      这里钉的是复用语义本身，防止将来误改成一次性窗口
//   §4 钳制取「窗口所在屏」，不是 NSScreen.main
//
//      run_probe settings_scroll_probe Sources/Models.swift Sources/Capture/ScreenGeometry.swift \
//          Sources/Preferences.swift Sources/HotkeyManager.swift Sources/LaunchAtLogin.swift \
//          Sources/History/CaptureHistory.swift Sources/Export/ImageEncode.swift \
//          Sources/SettingsWindow.swift
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
/// 为什么必须注入（O2）：钳制上限 = 可视高度 − 80，而可视高度随屏幕变 ——
/// 直接读本机 `NSScreen.main` 的话，「窗口多高」在不同机器上结论就不同，
/// 断言从「测行为」退化成「测这台机器的屏幕」。注入后，任何机器上都是同一组数字。
///
/// 注入点在 `present()` **之前**设：`present()` 末尾会重算一次窗口尺寸，
/// 那次重算才是最终生效的那次。
func openSettings(visibleHeight: CGFloat) -> (SettingsWindowController, NSWindow) {
    let controller = SettingsWindowController()
    controller.visibleHeightProvider = { visibleHeight }
    controller.present()
    let window = controller.window!
    window.layoutIfNeeded()   // 无 runloop 的探针里，几何断言前先冲一次布局
    return (controller, window)
}

/// 窗口内容高度（frame 减标题栏）。钳制作用在内容上，不是 frame 上。
func contentHeight(_ window: NSWindow) -> CGFloat {
    window.contentRect(forFrameRect: window.frame).height
}

func contentWidth(_ window: NSWindow) -> CGFloat {
    window.contentRect(forFrameRect: window.frame).width
}

/// 视图树里是否包含某个子视图（递归）。
///
/// 为什么不能用 `view.subviews.contains`：要问的是
/// 「清单容器在不在这个面板里」，而清单容器埋在
/// 滚动视图 → 文档容器 → 分组栈 → 行 好几层之下。
func containsView(_ root: NSView, _ target: NSView) -> Bool {
    if root === target { return true }
    return root.subviews.contains { containsView($0, target) }
}

/// 在视图树里找标题匹配的按钮。
func findButton(_ root: NSView, titled title: String) -> NSButton? {
    if let button = root as? NSButton, button.title == title { return button }
    for sub in root.subviews {
        if let hit = findButton(sub, titled: title) { return hit }
    }
    return nil
}

/// 侧栏当前选中的那一行是不是「忽略的应用」。
func selectedRowIsIgnoredApps(_ tree: NSOutlineView) -> Bool {
    guard tree.selectedRow >= 0, let item = tree.item(atRow: tree.selectedRow) else { return false }
    return (item as? SettingsWindowController.Section) == .ignoredApps
}

let originalIgnored = Preferences.shared.ignoredBundleIdentifiers
defer { Preferences.shared.ignoredBundleIdentifiers = originalIgnored }

print("=== 0. 纯函数：窗口尺寸规则（不依赖本机屏幕）===\n")
do {
    check("可视高 1440 → 钳制上限 1360",
          SettingsWindowController.clampMaxHeight(visibleHeight: 1440) == 1360,
          "\(SettingsWindowController.clampMaxHeight(visibleHeight: 1440))")
    check("可视高 1050 → 钳制上限 970",
          SettingsWindowController.clampMaxHeight(visibleHeight: 1050) == 970,
          "\(SettingsWindowController.clampMaxHeight(visibleHeight: 1050))")
    check("可视高 800 → 钳制上限 720",
          SettingsWindowController.clampMaxHeight(visibleHeight: 800) == 720,
          "\(SettingsWindowController.clampMaxHeight(visibleHeight: 800))")
    check("可视高 300 → 下限 320（极矮屏也不能窄到没法用）",
          SettingsWindowController.clampMaxHeight(visibleHeight: 300) == 320,
          "\(SettingsWindowController.clampMaxHeight(visibleHeight: 300))")

    // 窗口高度 = min(目标高 520, 钳制上限)
    check("可视高 1440 → 窗口高度 = 520（装得下就固定 520）",
          SettingsWindowController.contentHeight(visibleHeight: 1440) == 520,
          "\(SettingsWindowController.contentHeight(visibleHeight: 1440))")
    check("可视高 800 → 窗口高度 = 520",
          SettingsWindowController.contentHeight(visibleHeight: 800) == 520,
          "\(SettingsWindowController.contentHeight(visibleHeight: 800))")
    check("可视高 600 → 窗口高度 = 520（刚好等于上限）",
          SettingsWindowController.contentHeight(visibleHeight: 600) == 520,
          "\(SettingsWindowController.contentHeight(visibleHeight: 600))")
    check("可视高 500 → 窗口高度 = 420（被钳到上限）",
          SettingsWindowController.contentHeight(visibleHeight: 500) == 420,
          "\(SettingsWindowController.contentHeight(visibleHeight: 500))")
    check("可视高 300 → 窗口高度 = 320（钳制下限）",
          SettingsWindowController.contentHeight(visibleHeight: 300) == 320,
          "\(SettingsWindowController.contentHeight(visibleHeight: 300))")

    // 取哪块屏的规则：窗口所在屏优先，没有才退主屏
    check("窗口所在屏优先（不被主屏带偏）：窗口 1000 / 主屏 500 → 取 1000",
          SettingsWindowController.resolveVisibleHeight(windowScreenHeight: 1000,
                                                        mainScreenHeight: 500) == 1000)
    check("窗口不在任何屏上 → 退回主屏 500",
          SettingsWindowController.resolveVisibleHeight(windowScreenHeight: nil,
                                                        mainScreenHeight: 500) == 500)
    check("两块屏都没有 → 兜底 900",
          SettingsWindowController.resolveVisibleHeight(windowScreenHeight: nil,
                                                        mainScreenHeight: nil) == 900)
}

print("\n=== 1. 窗口高度固定：与忽略列表长度、与屏幕都无关 ===\n")
var emptyHeight: CGFloat = 0
var longHeight: CGFloat = 0
do {
    // 空列表
    Preferences.shared.ignoredBundleIdentifiers = []
    let (_, emptyWindow) = openSettings(visibleHeight: 1050)
    emptyHeight = contentHeight(emptyWindow)
    check("空忽略列表 → 窗口内容高度 = 520",
          abs(emptyHeight - 520) <= 1, "内容 \(Int(emptyHeight))")
    check("空忽略列表 → 窗口宽度 = 640",
          abs(contentWidth(emptyWindow) - 640) <= 1, "宽 \(Int(contentWidth(emptyWindow)))")
    emptyWindow.close()

    // 40 条列表：改版前页面会长到 2182pt，现在必须**一样高**
    Preferences.shared.ignoredBundleIdentifiers = (0..<40).map { "com.probe.ignored.app\($0)" }
    for visible in [800.0, 1050.0, 1440.0] {
        let (_, window) = openSettings(visibleHeight: visible)
        longHeight = contentHeight(window)
        check("40 条列表 · 可视高 \(Int(visible)) → 窗口高度仍是 520（列表不再撑窗口）",
              abs(longHeight - 520) <= 1, "内容 \(Int(longHeight))")
        // 钳制作用在**内容**上，不是 frame 上：frame 比内容高出来的那截是标题栏。
        check("40 条列表 · 可视高 \(Int(visible)) → 钳制作用在内容上（frame − 内容 = 标题栏）",
              (window.frame.height - longHeight) > 10 && (window.frame.height - longHeight) < 60,
              "差 \(Int(window.frame.height - longHeight))")
        window.close()
    }
    check("空列表与 40 条列表的窗口高度完全相同（列表长度与窗口解耦）",
          abs(emptyHeight - longHeight) <= 1,
          "空 \(Int(emptyHeight)) vs 长 \(Int(longHeight))")

    // 屏特别矮时才被钳（钳制上限 < 520）
    do {
        let (_, window) = openSettings(visibleHeight: 500)
        let expected = SettingsWindowController.contentHeight(visibleHeight: 500)
        check("超矮屏（可视高 500）→ 窗口高度 = 钳制上限 420",
              abs(contentHeight(window) - expected) <= 1,
              "内容 \(Int(contentHeight(window))) vs 上限 \(Int(expected))")
        window.close()
    }
}

print("\n=== 2. 侧栏结构：4 个顶层分组 + 1 个子面板 + 切换后只显示当前组 ===\n")
do {
    check("顶层分组共 4 个（快捷键 / 通用 / 高级 / 关于）",
          SettingsWindowController.Section.topLevel.count == 4,
          "\(SettingsWindowController.Section.topLevel.map(\.title).joined(separator: " / "))")
    check("顶层分组标题齐全",
          SettingsWindowController.Section.topLevel.map(\.title) == ["快捷键", "通用", "高级", "关于"],
          "\(SettingsWindowController.Section.topLevel.map(\.title).joined(separator: " / "))")
    check("侧栏条目共 5 个（4 顶层 + 1 子面板）",
          SettingsWindowController.Section.allCases.count == 5,
          "\(SettingsWindowController.Section.allCases.map(\.title).joined(separator: " / "))")
    check("「忽略的应用」是「快捷键」的子条目",
          SettingsWindowController.Section.ignoredApps.parent == .shortcuts
          && SettingsWindowController.Section.shortcuts.children == [.ignoredApps])
    check("其余 4 个分组没有子条目（只有一棵一层子树）",
          SettingsWindowController.Section.topLevel
            .filter { $0 != .shortcuts }
            .allSatisfy { $0.children.isEmpty })

    let (controller, window) = openSettings(visibleHeight: 1050)
    check("默认选中「快捷键」",
          controller.selectedSection == .shortcuts,
          "\(controller.selectedSection.title)")
    check("5 个面板都有内容视图",
          controller.sectionContentViews.count == 5,
          "\(controller.sectionContentViews.keys.map(\.title).joined(separator: " / "))")
    check("初始只有「快捷键」那一组可见",
          controller.sectionContentViews[.shortcuts]?.isHidden == false
          && controller.sectionContentViews[.ignoredApps]?.isHidden == true
          && controller.sectionContentViews[.general]?.isHidden == true
          && controller.sectionContentViews[.advanced]?.isHidden == true
          && controller.sectionContentViews[.about]?.isHidden == true)

    // 逐个切过去：当前组可见、其余全部隐藏
    for section in SettingsWindowController.Section.allCases {
        controller.selectSection(section)
        controller.window?.layoutIfNeeded()
        let visible = SettingsWindowController.Section.allCases.filter {
            controller.sectionContentViews[$0]?.isHidden == false
        }
        check("切到「\(section.title)」→ 只有这一组可见",
              visible == [section] && controller.selectedSection == section,
              "可见的是 \(visible.map(\.title).joined(separator: " / "))")
    }
    window.close()
}

print("\n=== 2b. 「忽略的应用」是独立子面板：清单不在快捷键组里 ===\n")
do {
    Preferences.shared.ignoredBundleIdentifiers = ["com.probe.ignored.one", "com.probe.ignored.two"]
    let (controller, window) = openSettings(visibleHeight: 1050)
    let tree = controller.sidebarTree

    check("侧栏共 5 行（「快捷键」默认展开，子条目可见）",
          tree.numberOfRows == 5, "\(tree.numberOfRows) 行")
    var row1Section: SettingsWindowController.Section?
    if let item = tree.item(atRow: 1) {
        row1Section = item as? SettingsWindowController.Section
    }
    check("侧栏第 2 行是「忽略的应用」（紧跟在「快捷键」下面，缩进一级）",
          row1Section == .ignoredApps
          && tree.isItemExpanded(SettingsWindowController.Section.shortcuts),
          "第 2 行是 \(row1Section?.title ?? "nil")")
    check("侧栏里只有「快捷键」是展开的父项",
          SettingsWindowController.Section.allCases
            .filter { controller.outlineView(tree, isItemExpandable: $0) } == [.shortcuts])

    // 核心不变量：清单容器在子面板里，**不在**快捷键组里
    guard let listBox = controller.ignoredAppsListContainer,
          let shortcutsView = controller.sectionContentViews[.shortcuts],
          let ignoredView = controller.sectionContentViews[.ignoredApps] else {
        check("能拿到清单容器与两个面板的视图", false)
        window.close()
        exit(1)
    }
    check("清单容器在「忽略的应用」面板里",
          containsView(ignoredView, listBox))
    check("清单容器**不**在快捷键组里（快捷键页只留摘要行）",
          !containsView(shortcutsView, listBox))

    // 摘要行：计数 + 「设置…」跳转按钮
    check("摘要行的计数与偏好一致（2 条）",
          controller.ignoredAppsSummaryCountLabel?.stringValue == "2 个应用",
          "\(controller.ignoredAppsSummaryCountLabel?.stringValue ?? "nil")")
    check("侧栏徽标的计数与偏好一致（2）",
          controller.sidebarCountBadge?.stringValue == "2",
          "\(controller.sidebarCountBadge?.stringValue ?? "nil")")
    check("快捷键页里能找到「设置…」按钮",
          findButton(shortcutsView, titled: "设置…") != nil)

    // 点「设置…」应当真的切到子面板（不是只改个标题）
    controller.selectSection(.shortcuts)
    controller.window?.layoutIfNeeded()
    findButton(controller.sectionContentViews[.shortcuts]!, titled: "设置…")?
        .performClick(nil)
    controller.window?.layoutIfNeeded()
    check("点「设置…」→ 切到「忽略的应用」子面板",
          controller.selectedSection == .ignoredApps
          && controller.sectionContentViews[.ignoredApps]?.isHidden == false,
          "\(controller.selectedSection.title)")
    check("切到子面板时侧栏选中行也跟着切过去",
          tree.selectedRow == 1 && selectedRowIsIgnoredApps(tree),
          "选中行 \(tree.selectedRow)")

    // 计数变化要跟着变（增删一条）
    Preferences.shared.ignoredBundleIdentifiers = ["com.probe.ignored.one"]
    controller.present()
    controller.window?.layoutIfNeeded()
    check("清单变动后摘要行计数跟着变（1 条）",
          controller.ignoredAppsSummaryCountLabel?.stringValue == "1 个应用",
          "\(controller.ignoredAppsSummaryCountLabel?.stringValue ?? "nil")")
    check("清单变动后侧栏徽标跟着变（1）",
          controller.sidebarCountBadge?.stringValue == "1",
          "\(controller.sidebarCountBadge?.stringValue ?? "nil")")
    window.close()
}

print("\n=== 2c. 清单长度与主页面长度解耦（步骤② 的核心承诺）===\n")
do {
    /// 分组文档高度（滚动视图的 documentView 撑多高）
    func documentHeight(_ view: NSView?) -> CGFloat {
        (view as? NSScrollView)?.documentView?.fittingSize.height ?? -1
    }
    /// 内容区可视高度
    func viewportHeight(_ view: NSView?) -> CGFloat {
        (view as? NSScrollView)?.contentView.bounds.height ?? -1
    }

    // 2 条时量一次
    Preferences.shared.ignoredBundleIdentifiers = ["com.probe.ignored.one", "com.probe.ignored.two"]
    let (shortController, shortWindow) = openSettings(visibleHeight: 1050)
    let shortShortcuts = documentHeight(shortController.sectionContentViews[.shortcuts])
    let shortIgnored = documentHeight(shortController.sectionContentViews[.ignoredApps])
    check("2 条清单 → 快捷键页文档高度 \(Int(shortShortcuts))pt（清单不在这一页）",
          shortShortcuts > 0 && shortShortcuts < 400,
          "\(Int(shortShortcuts))pt")
    shortWindow.close()

    // 40 条时再量一次：主页面必须一样高
    Preferences.shared.ignoredBundleIdentifiers = (0..<40).map { "com.probe.ignored.app\($0)" }
    let (longController, longWindow) = openSettings(visibleHeight: 1050)
    let longShortcuts = documentHeight(longController.sectionContentViews[.shortcuts])
    let longIgnored = documentHeight(longController.sectionContentViews[.ignoredApps])
    check("40 条清单 → 快捷键页文档高度与 2 条时**完全相同**（主页面与清单长度解耦）",
          abs(longShortcuts - shortShortcuts) <= 0.5,
          "2 条 \(Int(shortShortcuts))pt vs 40 条 \(Int(longShortcuts))pt")
    check("40 条清单 → 子面板文档高度 \(Int(longIgnored))pt（清单都在这一页）",
          longIgnored > shortIgnored,
          "2 条 \(Int(shortIgnored))pt vs 40 条 \(Int(longIgnored))pt")
    check("40 条清单 → 子面板超出可视高度（自己在里面滚）",
          longIgnored > viewportHeight(longController.sectionContentViews[.ignoredApps]),
          "内容 \(Int(longIgnored))pt vs 可视 \(Int(viewportHeight(longController.sectionContentViews[.ignoredApps])))pt")
    check("子面板有纵向滚动条",
          (longController.sectionContentViews[.ignoredApps] as? NSScrollView)?.hasVerticalScroller == true)
    check("窗口高度不受清单长度影响（仍是 520）",
          abs(contentHeight(longWindow) - 520) <= 1,
          "\(Int(contentHeight(longWindow)))pt")
    longWindow.close()
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

print("\n=== 4. 钳制取「窗口所在屏」，不是 NSScreen.main ===\n")
do {
    // `NSScreen.main` 是「当前持键盘焦点的屏幕」，不是窗口所在的屏。
    // 设置窗开在副屏时用它来钳高，就会被钳到主屏的高度 —— 副屏比主屏矮时
    // 窗口掉出副屏可视区，正是 E06 要修的那个 bug 的镜像。
    //
    // 怎么验：把设置窗挪到**非主屏**上，看「窗口有多高」是否按那块屏算。
    // 注意改版后窗口高度是**固定**的 —— 只有屏特别矮（钳制上限 < 520）时
    // 才看得出区别，所以本条在「大屏机器」上只能验到「窗口确实跟着那块屏」。
    let (_, probeWindow) = openSettings(visibleHeight: 4000)
    probeWindow.close()

    if let target = NSScreen.screens.first(where: { $0 != NSScreen.main }) {
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

        let expected = SettingsWindowController.contentHeight(
            visibleHeight: target.visibleFrame.height)
        let mainExpected = SettingsWindowController.contentHeight(
            visibleHeight: NSScreen.main?.visibleFrame.height ?? 900)
        check("窗口挪到 \(target.frame) 上 → 窗口.screen 跟着走",
              window.screen?.frame == target.frame,
              "\(String(describing: window.screen?.frame))")
        check("高度按**窗口所在屏**算（不是 NSScreen.main）",
              abs(contentHeight(window) - expected) <= 1,
              "内容 \(Int(contentHeight(window))) vs 该屏应为 \(Int(expected))")
        if expected == mainExpected {
            print("  ⏭️ 两块屏算出的高度一样（本机都是大屏，固定高度下本就分不出来）"
                  + "——「取哪块屏」的规则由 §0 的纯函数断言钉住")
        }
        window.close()
    } else {
        print("  ⏭️ 本机没有非主屏，跳过这一条")
    }
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
