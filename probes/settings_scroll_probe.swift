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

/// 视图树里收集某一类的视图。
func findAll<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
    var found: [T] = []
    if let hit = root as? T { found.append(hit) }
    for sub in root.subviews {
        found.append(contentsOf: findAll(sub, of: type))
    }
    return found
}

/// 一行「标签列 + 控件」。
struct LabelRow {
    let row: NSStackView
    let column: NSView
    let control: NSView
    var text: String { (column.subviews.first as? NSTextField)?.stringValue ?? "" }
}

/// 找出所有「标签列 + 控件」行 —— **按结构认，不按控件类型认**。
///
/// 为什么不再按 `NSPopUpButton` 找（2026-11-12 复核）：那样只看得见通用组的
/// 状态栏三行，快捷键组的两个录制按钮、通用组的强度滑杆、高级组的地址输入框
/// 全都测不到 —— 而「标签列 96pt、控件左边界对齐」这条规范说的是**所有**行。
/// 按类型找还有个更坏的后果：新加一行别的控件，探针不会红，只会默默漏掉。
///
/// 标签列的结构签名（见 `SettingsWindowController.makeLabelColumn`）：
/// 横向 stack 的第一个 arranged subview 是**恰好一个 NSTextField 的裸 NSView**。
/// 说明行（首个是 NSTextField）、按钮行（首个是 NSButton）、忽略清单行
/// （首个是 NSTextField）都不满足，实测 5 组共 8 行、零误判。
func labelRows(in root: NSView) -> [LabelRow] {
    findAll(root, of: NSStackView.self).compactMap { row in
        guard row.orientation == .horizontal,
              row.arrangedSubviews.count >= 2,
              let column = row.arrangedSubviews.first,
              type(of: column) == NSView.self,
              column.subviews.count == 1,
              column.subviews[0] is NSTextField
        else { return nil }
        return LabelRow(row: row, column: column, control: row.arrangedSubviews[1])
    }
}

/// 侧栏当前选中的那一行是不是「忽略的应用」。
func selectedRowIsIgnoredApps(_ tree: NSOutlineView) -> Bool {
    guard tree.selectedRow >= 0, let item = tree.item(atRow: tree.selectedRow) else { return false }
    return (item as? SettingsWindowController.Section) == .ignoredApps
}

/// 底部状态区的当前文案（状态区是私有控件，从视图树按内容认）。
///
/// 为什么不加 `statusText` 访问器了：探针能自己从视图树拿到的东西就不必
/// 为它开生产代码的口子 —— 与「ⓘ 弹层用 contentViewController?.view 拿」同一思路。
func statusLabelText(_ c: SettingsWindowController) -> String {
    guard let root = c.window?.contentView else { return "" }
    return findAll(root, of: NSTextField.self)
        .map(\.stringValue)
        .first { $0.contains("已恢复默认设置") || $0.contains("测试：热键注册失败") } ?? ""
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

print("\n=== 3b. 视觉规范：间距 8/24 + 标签列 96pt + 输入框自适应（步骤③a）===\n")
do {
    let (controller, window) = openSettings(visibleHeight: 1050)
    window.layoutIfNeeded()

    // 每组的**结构规模**用字面量钉住，5 组一个不落。
    //
    // 为什么必须逐组给期望值、不能只写 allSatisfy：某组一行都没找到时
    // allSatisfy 恒真 —— 断言看着绿，其实什么都没测。数字是 2026-11-12 实测。
    //
    // 标签文本连**顺序**一起钉：顺序就是屏幕上的行序，只比个数的话
    // 「把『中键』那行换成别的」不会被发现。
    let expectedSeparators: [SettingsWindowController.Section: Int] = [
        .shortcuts: 1, .ignoredApps: 0, .general: 4, .advanced: 0, .about: 1,
    ]
    let expectedLabels: [SettingsWindowController.Section: [String]] = [
        .shortcuts: ["区域截图", "窗口截图", "忽略的应用"],
        .ignoredApps: [],
        .general: ["左键", "右键", "中键", "强度"],
        .advanced: ["清单地址"],
        .about: [],
    ]

    for section in SettingsWindowController.Section.allCases {
        guard let stack = controller.groupStacks[section],
              let view = controller.sectionContentViews[section] else {
            check("能拿到「\(section.title)」组的根栈与内容视图", false)
            continue
        }
        let host = (view as? NSScrollView)?.documentView ?? view

        // ── 间距：组内 8、子分区之间 24 ──
        //
        // **数值用字面量、不跟着代码里的常量走**：改成常量引用的话，
        // 有人把常量从 8 改成 12，断言会拿新常量当期望值 → 恒真 → 探针形同虚设
        // （O2 的教训）。这里钉的是**设计规范里的数**。
        check("「\(section.title)」组内间距 = 8",
              stack.spacing == 8, "\(stack.spacing)")
        let separators = findAll(stack, of: NSBox.self).filter { $0.boxType == .separator }
        check("「\(section.title)」分隔线条数 = \(expectedSeparators[section]!)",
              separators.count == expectedSeparators[section]!,
              "\(separators.count) 条")
        if !separators.isEmpty {
            let gaps = separators.map { stack.customSpacing(after: $0) }
            check("「\(section.title)」每条分隔线后都是 24pt 组间距（组间 24 > 组内 8）",
                  gaps.allSatisfy { $0 == 24 }, "\(gaps)")
        }

        // ── 标签列：同页控件左边界一致 ──
        let rows = labelRows(in: host)
        check("「\(section.title)」的标签行 = \(expectedLabels[section]!)",
              rows.map { $0.text } == expectedLabels[section]!,
              "\(rows.map { $0.text })")
        if !rows.isEmpty {
            // 宽度要量 **alignmentRect**（有效布局列）而不是 frame：
            // NSButton/NSTextField 默认有 2pt 的 alignmentRectInsets，
            // frame 会比实际占位大 4pt。裸 NSView 容器两者相同（实测都是 96）。
            let widths = rows.map { $0.column.alignmentRect(forFrame: $0.column.frame).width }
            check("「\(section.title)」每个标签列有效宽 = 96pt",
                  widths.allSatisfy { abs($0 - 96) <= 0.5 },
                  "\(widths.map { Int($0) })")
            // 行内相对偏移：标签列 → 控件。这条与控件类型无关 ——
            // NSStackView 按 alignmentRect 排布，所以按钮/标签/下拉/滑杆
            // 都该是 96 + 12。按 frame 量会因各自的 alignmentRectInsets 差几 pt。
            let offsets = rows.map {
                $0.control.alignmentRect(forFrame: $0.control.frame).minX
                    - $0.column.alignmentRect(forFrame: $0.column.frame).minX
            }
            check("「\(section.title)」每行控件紧跟 96pt 标签列之后（行内间距 12）",
                  offsets.allSatisfy { abs($0 - (96 + 12)) <= 0.5 },
                  "\(offsets.map { Int($0) })")
            // 换算到窗口坐标的**对齐**左边界：这才是「控件左边界一致」的真身。
            // 实测 8 行全是 296.00 —— 而 frame 左边界因控件类型不同散在 289~296，
            // 拿 frame 比会误判成「没对齐」。
            let lefts = rows.map {
                $0.row.convert($0.control.alignmentRect(forFrame: $0.control.frame), to: nil).minX
            }
            check("「\(section.title)」所有控件左边界一致（跨控件类型）",
                  Set(lefts.map { ($0 * 2).rounded() }).count == 1,
                  "\(lefts.map { String(format: "%.1f", $0) })")
        }

        // ── 文档高度装得下全部内容（E06 根因，逐组版）──
        //
        // 期望值是**推出来的**，不是魔数：文档高 = 内容最高沿 + 上内边距。
        // 缺 bottom 约束时 fittingSize 塌成 0，这条必红。
        // 注意 stack **不翻转**（原点在左下），所以「内容顶」是 maxY 的最大值。
        let rects = stack.arrangedSubviews.map { $0.alignmentRect(forFrame: $0.frame) }
        let contentTop = rects.map { $0.maxY }.max() ?? 0
        let contentBottom = rects.map { $0.minY }.min() ?? 0
        check("「\(section.title)」文档高度 = 内容顶 + 上内边距（没有内容被裁掉）",
              abs(host.fittingSize.height - (contentTop + stack.edgeInsets.top)) <= 0.5,
              "文档 \(host.fittingSize.height) vs 内容顶 \(contentTop) + \(stack.edgeInsets.top)")
        check("「\(section.title)」内容底边落在下内边距上（约束完整）",
              abs(contentBottom - stack.edgeInsets.bottom) <= 0.5,
              "\(contentBottom) vs \(stack.edgeInsets.bottom)")
    }

    // ── 输入框宽度跟随内容区 ──
    guard let feed = controller.updateFeedURLField else {
        check("能拿到清单地址输入框", false)
        exit(1)
    }
    let feedRight = feed.convert(feed.bounds, to: nil).maxX
    let expectedRight = SettingsWindowController.preferredContentWidth
        - SettingsWindowController.groupEdgeInset
    check("URL 输入框右边界 = 内容区右边界（自适应铺满）",
          abs(feedRight - expectedRight) <= 1,
          "\(Int(feedRight)) vs \(Int(expectedRight))")
    let expectedWidth = SettingsWindowController.contentTextWidth - 96 - 12
    check("URL 输入框宽度 = 内容区 − 标签列 96 − 间距 12（不再是写死的 320）",
          abs(feed.bounds.width - expectedWidth) <= 1,
          "\(Int(feed.bounds.width)) vs \(Int(expectedWidth))")
    check("URL 输入框没有溢出内容区",
          feedRight <= expectedRight + 0.5,
          "\(Int(feedRight))")
    window.close()
}

print("\n=== 3c. 文案规范：说明一行 ≤40 字 + 细节进 ⓘ 弹层（步骤③b）===\n")
do {
    let (controller, window) = openSettings(visibleHeight: 1050)
    window.layoutIfNeeded()

    // ── 分区标题统一 13pt semibold ──
    // 一次比「字号 + 字重」两件事：NSFont 没有 weight 属性，
    // 直接和 systemFont(13, .semibold) 比更省事，也更严。
    let expectedTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let oddTitles = controller.sectionTitles.filter { $0.font != expectedTitleFont }
    check("分区标题统一 13pt semibold",
          !controller.sectionTitles.isEmpty && oddTitles.isEmpty,
          "不一致的：\(oddTitles.map { "\($0.stringValue)(\($0.font?.pointSize ?? -1))" })")

    // ── 说明文字：每条最多一行、每条不超过 40 字 ──
    let hints = controller.hintLabels
    check("有说明文字可查",
          hints.count >= 8, "\(hints.count) 条")
    let longHints = hints.filter { $0.stringValue.count > 40 }
    check("每条说明都 ≤ 40 字",
          longHints.isEmpty,
          "超长的：\(longHints.map { $0.stringValue })")
    // 一行 = 高度不超过一行行高（11pt 字约 15pt，给 20pt 仍算一行）
    let tallHints = hints.filter { $0.bounds.height > 20 }
    check("每条说明都只占一行",
          tallHints.isEmpty,
          "多行的：\(tallHints.map { "\($0.stringValue.prefix(8))(\(Int($0.bounds.height))pt)" })")

    // ── ⓘ 按钮：不溢出内容区 ──
    let contentRight = SettingsWindowController.preferredContentWidth
        - SettingsWindowController.groupEdgeInset
    let overflowing = controller.detailButtons.filter {
        $0.convert($0.bounds, to: nil).maxX > contentRight + 0.5
    }
    check("ⓘ 按钮都没有溢出内容区右缘",
          overflowing.isEmpty,
          "溢出 \(overflowing.count) 个")
    check("ⓘ 按钮数量与弹层数量一致",
          controller.detailPopovers.count == controller.detailButtons.count,
          "\(controller.detailPopovers.count) / \(controller.detailButtons.count)")

    // ── 弹层有内容、点了能打开 ──
    let emptyPopovers = controller.detailPopovers.filter {
        $0.contentSize.width <= 0 || $0.contentSize.height <= 0
    }
    check("每个弹层都有尺寸（不是空的）",
          emptyPopovers.isEmpty,
          "空的 \(emptyPopovers.count) 个")
    if let button = controller.detailButtons.first,
       let popover = controller.detailPopovers.first {
        button.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        check("点 ⓘ 能打开详情弹层",
              popover.isShown,
              popover.isShown ? "" : "没打开")
        popover.performClose(nil)
    } else {
        check("有可点的 ⓘ 按钮", false)
    }
    window.close()
}

print("\n=== 3d. 危险操作归位：恢复默认在「关于」+ 二次确认 + 列出影响项（步骤④）===\n")
do {
    let (controller, window) = openSettings(visibleHeight: 1050)
    controller.selectSection(.about)
    // 注入一条假失败：确认路径必须让它留在状态区（P1-2 的回归网）。
    controller.onHotkeysChanged = { ["测试：热键注册失败"] }
    window.layoutIfNeeded()

    // ── 位置：恢复默认在「关于」组，不在别处 ──
    let aboutButtons = findAll(controller.sectionContentViews[.about]!, of: NSButton.self)
    check("「恢复全部默认设置」在「关于」组里",
          aboutButtons.contains { $0.title == "恢复全部默认设置" })
    check("「恢复默认快捷键」也在「关于」组里",
          aboutButtons.contains { $0.title == "恢复默认快捷键" })
    for section in [SettingsWindowController.Section.shortcuts,
                     .ignoredApps, .general, .advanced] {
        let others = findAll(controller.sectionContentViews[section]!, of: NSButton.self)
        check("「恢复全部默认设置」不在「\(section.title)」组里",
              !others.contains { $0.title == "恢复全部默认设置" })
    }

    // ── 确认框必须逐条列出影响项（E01b 的留存语义）──
    let summary = SettingsWindowController.resetAllImpactSummary(ignoredAppCount: 3)
    for keyword in ["线宽", "颜色", "水印", "快捷键", "忽略的应用", "状态栏",
                     "截图历史", "不会被删除"] {
        check("确认框文案提到「\(keyword)」",
              summary.contains(keyword),
              summary)
    }
    // 上面是抽查几个词；这里是**逐项**核对：会重置的每一项都得在文案里出现。
    //
    // 清单来自 `Preferences.resetDisclosures`（由 Key 的穷尽 switch 生成），
    // 与 `resetToDefaults()` 遍历的是同一个 allCases —— 于是「加了偏好键」
    // 「忘了写进确认框」这件事会在这里红，而不是等用户事后发现。
    // 两侧是不同代码（键的说法 vs 确认框散文），所以不是自证。
    let disclosures = Preferences.resetDisclosures
    check("有可核对的重置项说法", !disclosures.isEmpty, "\(disclosures.count) 项")
    for word in disclosures {
        check("确认框列出了会被重置的「\(word)」", summary.contains(word), summary)
    }
    check("确认框写明忽略应用的数量（3 个）",
          summary.contains("3 个"),
          summary)
    // ⓘ 详情里那句「一次会改 N 项」的 N 必须等于真实项数，不能是写死的旧数字。
    // 弹层正文是 **NSTextView**（不是 NSTextField，理由见 DetailButton 的注释）。
    let popoverTexts = controller.detailPopovers.compactMap {
        $0.contentViewController?.view
    }.flatMap { findAll($0, of: NSTextView.self) }.map { $0.string }
    let countClaims = popoverTexts.filter { $0.contains("一次会改") }
    check("ⓘ 详情里有「一次会改 N 项」这句",
          countClaims.count == 1, "\(countClaims)")
    check("那句里的 N = 真实重置项数（\(Preferences.resettableCount)）",
          countClaims.allSatisfy { $0.contains("一次会改 \(Preferences.resettableCount) 项") },
          "\(countClaims)")

    // ── 二次确认：点了但没确认 → 偏好一个都不许动 ──
    let savedWidth = Preferences.shared.lineWidth
    let savedStrength = Preferences.shared.redactionStrength
    let savedSnap = Preferences.shared.snapSelectionToWindows
    defer {
        Preferences.shared.lineWidth = savedWidth
        Preferences.shared.redactionStrength = savedStrength
        Preferences.shared.snapSelectionToWindows = savedSnap
    }
    // 按用户视角摆：先改过这几项，再来点「恢复全部默认设置」
    let general = controller.sectionContentViews[.general]!
    let slider = findAll(general, of: NSSlider.self).first
    let snapBox = findAll(general, of: NSButton.self)
        .first { $0.title.contains("选区边缘自动吸附") }
    Preferences.shared.lineWidth = 7.5
    Preferences.shared.redactionStrength = 2.5
    Preferences.shared.snapSelectionToWindows = false
    // 控件也要**真的动过** —— 用户是拖滑杆、点勾选框，不是改偏好。
    // 只改偏好的话控件停在构造时的值（恰好是缺省值），"重置后控件同步"
    // 这条断言在删掉刷新代码时也会绿：变异测试 M3（删 refreshFromPreferences
    // 里的滑杆刷新）实证过这个假绿。所以必须先动控件再重置。
    if let slider = slider, let action = slider.action {
        slider.doubleValue = 2.5
        _ = NSApp.sendAction(action, to: slider.target, from: slider)
    }
    if let box = snapBox, let action = box.action {
        box.state = .off
        _ = NSApp.sendAction(action, to: box.target, from: box)
    }
    check("操作后控件与偏好一致（2.5× / 关）",
          abs((slider?.doubleValue ?? -1) - 2.5) < 0.01 && snapBox?.state == .off,
          "滑杆 \(slider?.doubleValue ?? -1) 勾选框 \(snapBox?.state.rawValue ?? -1)")
    controller.present()          // 顺序即用户操作顺序
    window.layoutIfNeeded()

    let resetAllButton = aboutButtons.first { $0.title == "恢复全部默认设置" }
    resetAllButton?.performClick(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    check("确实弹出了确认框",
          controller.pendingResetAlert != nil)
    check("点「恢复全部默认设置」但未确认 → 偏好不动（确实有二次确认）",
          Preferences.shared.lineWidth == 7.5,
          "\(Preferences.shared.lineWidth)")
    if let alert = controller.pendingResetAlert {
        check("确认框标题写明是危险操作",
              alert.messageText.contains("恢复全部默认设置"),
              alert.messageText)
        let cancel = alert.buttons.first { $0.title == "取消" }
        check("默认按钮是「取消」（不可逆操作不该手一抖回车就执行）",
              alert.window.defaultButtonCell === cancel?.cell,
              "默认按钮 = \(alert.window.defaultButtonCell?.title ?? "nil")")
        check("确认框里没有默认的「直接恢复」按钮",
              !alert.buttons.contains { $0.title == "恢复" },
              "\(alert.buttons.map { $0.title })")

        // ── 确认框**实际显示**的就是影响项文案（P1-3 的锚点）──
        //
        // 2026-11-12 评审：原探针只断言自己调用的纯函数
        // `resetAllImpactSummary(ignoredAppCount: 3)`，从未读
        // `alert.informativeText` —— 变异测试实证，把实现改成
        // `alert.informativeText = "确定？"` 后探针仍 149 项全绿。
        // 锚点必须落在用户看见的那个对象上。
        let liveSummary = SettingsWindowController.resetAllImpactSummary(
            ignoredAppCount: Preferences.shared.ignoredBundleIdentifiers.count)
        check("确认框实际显示的就是影响项文案（锚在 alert，不是纯函数）",
              alert.informativeText == liveSummary,
              alert.informativeText == liveSummary ? "" : "实现与文案已漂移")
        check("影响项文案写明历史文件不删、开机启动不在范围内",
              liveSummary.contains("不会被删除") && liveSummary.contains("开机自动启动"),
              liveSummary)

        // ── 取消：清空写在响应分支**之前**，两条响应共用同一句，走这条路验 ──
        cancel?.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("取消之后 pendingResetAlert 已清空（不留悬挂的确认框）",
              controller.pendingResetAlert == nil,
              controller.pendingResetAlert == nil ? "" : "仍持有 alert")
        check("取消之后偏好仍然不动",
              Preferences.shared.lineWidth == 7.5,
              "\(Preferences.shared.lineWidth)")
    }

    // ── 确认路径：把整个 resetToDefaults 走完（此前完全没覆盖）──
    //
    // 同时钉住三件评审实证过的事：
    // ① 确认之后 pendingResetAlert 也清空（两条响应共用同一句，此前只验了取消）；
    // ② 偏好回缺省**且控件跟着回**（P1-1：滑杆/数值标签/勾选框原来停在旧值）；
    // ③ 注入的热键注册失败必须留在状态区（P1-2：原来被成功文案无条件覆盖）。
    do {
        resetAllButton?.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let alert = controller.pendingResetAlert,
              let confirm = alert.buttons.first(where: { $0.title == "恢复默认" }) else {
            check("确认路径：再次弹出确认框", false)
            window.close()
            exit(1)
        }
        confirm.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()

        check("确认之后 pendingResetAlert 也清空（不只取消路径）",
              controller.pendingResetAlert == nil,
              controller.pendingResetAlert == nil ? "" : "仍持有 alert")
        check("确认之后偏好回缺省：线宽 15",
              abs(Preferences.shared.lineWidth - 15) < 0.01, "\(Preferences.shared.lineWidth)")
        check("确认之后偏好回缺省：打码强度 1.0",
              abs(Preferences.shared.redactionStrength - 1.0) < 0.01,
              "\(Preferences.shared.redactionStrength)")
        check("确认之后偏好回缺省：吸附开",
              Preferences.shared.snapSelectionToWindows == true,
              "\(Preferences.shared.snapSelectionToWindows)")
        check("确认之后偏好回缺省：忽略的应用清空",
              Preferences.shared.ignoredBundleIdentifiers.isEmpty,
              "\(Preferences.shared.ignoredBundleIdentifiers)")

        check("★ 滑杆跟着回 1.0（P1-1：原来停在用户改过的值）",
              abs((slider?.doubleValue ?? -1) - 1.0) < 0.01,
              "滑杆 \(slider?.doubleValue ?? -1)")
        check("★ 强度标签跟着回 1.0×（P1-1）",
              findAll(general, of: NSTextField.self).contains { $0.stringValue == "1.0×" })
        check("★ 吸附勾选框跟着回到开（P1-1）",
              snapBox?.state == .on,
              "state \(snapBox?.state.rawValue ?? -1)")
        check("★ 状态区保留热键注册失败（P1-2：原来被成功文案覆盖）",
              statusLabelText(controller).contains("测试：热键注册失败"),
              statusLabelText(controller))
        check("状态区同时说明已恢复默认",
              statusLabelText(controller).contains("已恢复默认设置"),
              statusLabelText(controller))
    }
    window.close()
}

print("\n=== 3e. 关窗收尾：录制状态与地址输入不悬挂（评审 P2-2）===\n")
do {
    // 设置窗是常驻单例（isReleasedWhenClosed = false + AppDelegate 强持有），
    // deinit 永不触发 —— 「录制中点关闭按钮」只能靠 windowWillClose 收尾。
    // 评审实证：修复前关窗后按钮仍显示「按下新的组合键…」，
    // 本地键盘监视器会继续吞掉其它窗口的 keyDown。
    let (controller, window) = openSettings(visibleHeight: 1050)
    controller.onHotkeysChanged = { [] }
    let shortcuts = controller.sectionContentViews[.shortcuts]!
    let regionTitle = Preferences.shared.regionCaptureHotkey.displayString
    guard let recordButton = findAll(shortcuts, of: NSButton.self)
            .first(where: { $0.title == regionTitle }) else {
        check("能找到区域截图录制按钮", false)
        window.close()
        exit(1)
    }
    recordButton.performClick(nil)
    check("点录制后按钮显示提示文案",
          recordButton.title == "按下新的组合键…", recordButton.title)
    window.close()
    check("★ 关窗后录制状态被清掉（按钮还原成实际快捷键）",
          recordButton.title == regionTitle,
          recordButton.title == regionTitle ? "" : "仍是「\(recordButton.title)」= stopRecording 没跑")

    // 地址输入框的 action 只在回车/失焦时触发：直接关窗原来会丢掉输入。
    controller.present()
    window.layoutIfNeeded()
    let advanced = controller.sectionContentViews[.advanced]!
    let urlField = findAll(advanced, of: NSTextField.self).first {
        $0.placeholderString?.contains("latest.json") == true
    }
    let savedFeed = Preferences.shared.updateFeedURL
    defer { Preferences.shared.updateFeedURL = savedFeed }
    urlField?.stringValue = "https://review.example/feed.json"   // 只改 UI，不触发 action
    window.close()
    check("★ 关窗时提交未失焦的地址输入",
          Preferences.shared.updateFeedURL == "https://review.example/feed.json",
          Preferences.shared.updateFeedURL)
    controller.present()
    check("再打开时输入框显示刚保存的地址",
          urlField?.stringValue == "https://review.example/feed.json",
          urlField?.stringValue ?? "nil")
    window.close()
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
