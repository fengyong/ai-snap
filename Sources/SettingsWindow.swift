import Cocoa
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// 偏好设置窗口。
///
/// 这里只放**没有别的入口**的设置：全局快捷键（含忽略应用列表）、状态栏按键动作、
/// 开机启动、截图历史、更新。线宽、颜色、线型、箭头样式、水印已经在标注窗口的工具栏里，
/// **再放一份到这里只会造出两个能改同一份数据的地方**
/// （改了一处另一处不刷新，用户看到的状态就自相矛盾）。
///
/// **2026-11-12 · 改版为分类侧栏**：原实现把 8 个分区平铺在一根 1162pt 高的列上
/// （实测，空忽略列表时），窗口按内容高度撑开、再钳到屏幕可视区 —— 于是**开窗即满屏
/// 且永远带滚动条**，连「忽略列表为空」时也是（钳制上限 970~1042pt < 内容 1162pt）。
///
/// 根因不是「设置项太多」，而是**信息架构没有分层**：每天都要用的截图快捷键，
/// 和几乎不碰的更新清单地址，同层同权重、同样的标题、同样的分隔线、同样的间距 ——
/// 代价由用户每次开窗承担。
///
/// 改法（对齐《产品设计改进方案-2026-10-19》§10.2「分类侧栏／分段导航＋内容滚动」，
/// 当年只落地了 E06 的滚动容器，把「内容可达」解决了，没解决「开窗即满屏」）：
/// ① 左侧分类侧栏 4 组（快捷键 / 通用 / 高级 / 关于），右侧只显示当前组；
/// ② 窗口尺寸**固定**，不再随内容变化 —— 内容超出由内容区自己滚；
/// ③ 状态提示挪到窗口底部常驻（原来在长页面顶部，出错时滚下去就找不着了）。
final class SettingsWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    // MARK: - 侧栏分组

    /// 侧栏条目。既是分组也是面板 —— 一个条目对应右侧一块内容。
    ///
    /// 顶层 4 组（快捷键 / 通用 / 高级 / 关于）+ 1 个子面板（快捷键下的「忽略的应用」）。
    ///
    /// **为什么「忽略的应用」要独立成子面板（2026-11-12）**：它回答的是
    /// 「哪些地方**不**按快捷键」，不是「快捷键怎么设」—— 混在快捷键组里，
    /// 主页面既不像配置也不像清单。更要紧的是它**长度不可控**：
    /// 实测 40 条清单 = 1020pt，放在主页面里就会把「恢复默认」之类低频入口
    /// 推到几千点之外。独立之后，主页面长度与清单长度彻底解耦。
    enum Section: Int, CaseIterable {
        case shortcuts, ignoredApps, general, advanced, about

        var title: String {
            switch self {
            case .shortcuts: return "快捷键"
            case .ignoredApps: return "忽略的应用"
            case .general: return "通用"
            case .advanced: return "高级"
            case .about: return "关于"
            }
        }

        var symbolName: String {
            switch self {
            case .shortcuts: return "keyboard"
            case .ignoredApps: return "eye.slash"
            case .general: return "gearshape"
            case .advanced: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }

        /// 父条目。nil = 顶层分组。
        var parent: Section? {
            switch self {
            case .ignoredApps: return .shortcuts
            case .shortcuts, .general, .advanced, .about: return nil
            }
        }

        /// 子条目（「忽略的应用」是「快捷键」的唯一子条目）。
        var children: [Section] {
            Section.allCases.filter { $0.parent == self }
        }

        /// 顶层分组（侧栏第一层）。顺序即侧栏里的显示顺序。
        static var topLevel: [Section] {
            allCases.filter { $0.parent == nil }
        }
    }

    /// 窗口目标宽度。侧栏 168 + 内容区 472 —— 内容区减去左右内边距 40 后剩 432，
    /// 装得下现在最宽的一行（清单地址行：标签 80 + 间距 12 + 输入框 320 = 412）。
    static let preferredContentWidth: CGFloat = 640
    /// 窗口目标高度。**固定**：与内容、与忽略列表长度都无关。
    static let preferredContentHeight: CGFloat = 520
    /// 侧栏宽度
    static let sidebarWidth: CGFloat = 168

    /// 快捷键改动后由外部（AppDelegate）重新注册，并把问题反馈回来。
    /// 用闭包而不是让设置窗口去调 AppDelegate，避免两边互相持有。
    var onHotkeysChanged: (() -> [String])?

    /// 「立即检查更新」交给 AppDelegate 去执行 —— 检查完要弹窗、还要打开浏览器，
    /// 那是应用级的事情，不是设置窗口的职责。
    var onCheckForUpdates: (() -> Void)?

    /// 钳制用的「屏幕可视高度」来源。默认取**窗口实际所在**屏（见 `screenVisibleHeight(for:)`）。
    ///
    /// 做成注入点是为了**可测**：钳制上限随屏幕变 —— 原来探针直接读本机 `NSScreen.main`，
    /// 于是「窗口多高」在不同机器上结论不同，红灯常态化 = 回归网失效。
    /// 探针给定固定高度后，任何机器上都是同一组数字。
    var visibleHeightProvider: (() -> CGFloat)?

    /// 当前选中的分组。internal 供探针断言「切换分组真的换了内容」。
    private(set) var selectedSection: Section = .shortcuts
    /// 各分组的内容视图。internal 供探针断言「只有当前组可见」。
    private(set) var sectionContentViews: [Section: NSView] = [:]
    /// 侧栏树控件。internal 供探针断言侧栏结构（4 顶层 + 1 子项、子项挂在谁下面）。
    var sidebarTree: NSOutlineView { sidebarOutline }
    /// 「忽略的应用」清单容器。internal 供探针断言「清单在子面板里，不在快捷键组里」。
    var ignoredAppsListContainer: NSView? { ignoredAppsBox }
    /// 快捷键页摘要行上的清单计数标签。internal 供探针断言「计数与偏好一致」。
    private(set) var ignoredAppsSummaryCountLabel: NSTextField?
    /// 侧栏「忽略的应用」条目右侧的计数徽标。
    private(set) var sidebarCountBadge: NSTextField?

    private var regionButton: NSButton!
    private var windowButton: NSButton!
    private var statusLabel: NSTextField!
    private var feedURLField: NSTextField!
    private var autoCheckBox: NSButton!
    private var launchAtLoginBox: NSButton!
    private var recordHistoryBox: NSButton!
    /// 忽略应用列表的行容器（列表变化时整体重建）
    private var ignoredAppsBox: NSStackView!
    /// 状态栏左/右/中键动作下拉框
    private var trayLeftPopup: NSPopUpButton!
    private var trayRightPopup: NSPopUpButton!
    private var trayMiddlePopup: NSPopUpButton!
    /// 打码强度滑杆与数值标签
    private var redactionStrengthSlider: NSSlider!
    private var redactionStrengthLabel: NSTextField!
    /// 选区吸附窗口开关
    private var snapToWindowsBox: NSButton!
    private var keyMonitor: Any?
    /// 侧栏控件
    private var sidebarOutline: NSOutlineView!
    /// 内容区宿主（各分组滚动视图的父视图）
    private var contentContainer: NSView!
    /// 正在录制的目标：nil 表示没有在录制
    private var recordingTarget: RecordingTarget?

    /// 切换分组时抑制回调：程序化选中侧栏行会再次触发选中回调，
    /// 不加这道闸会来回弹。
    private var isSwitchingSection = false

    private enum RecordingTarget {
        case region
        case window
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: SettingsWindowController.preferredContentWidth,
                                height: SettingsWindowController.preferredContentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AISnap 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
        refreshFromPreferences()
    }

    deinit {
        stopRecording()
    }

    // MARK: - UI

    private func buildUI() {
        guard let window = window else { return }

        // ── 状态区（常驻底部）──
        //
        // 原来状态提示在长页面的顶部（快捷键区下面）：出错时用户已经滚到别的分区，
        // 那条提示根本看不见。现在它常驻在窗口底部，跟当前分组无关 ——
        // 「组合键不合法」「必须留一个弹出菜单」「恢复默认会影响哪些项」都要能看见。
        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .systemOrange
        statusLabel.isHidden = true
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = Self.preferredContentWidth - 40

        let footer = NSStackView(views: [statusLabel])
        footer.orientation = .horizontal
        footer.alignment = .leading
        footer.spacing = 0
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 20, bottom: 10, right: 20)

        // ── 侧栏 ──
        let sidebar = makeSidebarView()

        // ── 内容区：4 组各一个滚动视图叠在一起，只显示当前组 ──
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        for section in Section.allCases {
            let scroll = makeGroupScrollView(buildSectionContent(section))
            scroll.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
            sectionContentViews[section] = scroll
        }

        let root = NSView()
        // 内容视图的尺寸由窗口管（translatesAutoresizingMaskIntoConstraints 保持默认 true）：
        // 设成 false 会让 Auto Layout 接管根视图，而根视图没有高度最小值约束 ——
        // 结果内容区高度塌成 0（整页空白，只剩侧栏）。
        window.contentView = root
        root.addSubview(sidebar)
        root.addSubview(contentContainer)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: footer.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: footer.topAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // 内容区宽度写死：窗口不可缩放，少了这道约束 Auto Layout 会把根视图
        // 收成「侧栏宽度」（内容区没有内在尺寸 → 取最小值 0）。
        contentContainer.widthAnchor.constraint(
            equalToConstant: Self.preferredContentWidth - Self.sidebarWidth).isActive = true

        selectSection(.shortcuts)
        // 「快捷键」默认展开：子条目「忽略的应用」得**看得见** ——
        // 收起的话用户根本不知道有这个页面，等于把入口藏起来了。
        // 5 行 × 30pt = 150pt，在 520pt 高的窗口里绰绰有余。
        sidebarOutline.expandItem(Section.shortcuts)
        fitWindowToContent()
        // 尺寸定下来之后再居中：构造时的 center() 用的是临时尺寸，
        // setContentSize 之后窗口会偏。
        window.center()
    }

    /// 侧栏：源列表样式（macOS 系统设置那种）。
    ///
    /// 用 NSOutlineView 而不是 NSTableView：分组将来可能有子项
    /// （例如「忽略的应用」从快捷键里独立出去），outline 天然支持层级。
    private func makeSidebarView() -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = nil
        outline.rowHeight = 30
        outline.floatsGroupRows = false
        outline.style = .sourceList          // macOS 12+ 的 sourceList 样式（系统设置那种）
        outline.dataSource = self
        outline.delegate = self
        // 子条目（"忽略的应用"）要缩进一级，否则它和顶层分组平齐，
        // 用户看不出谁属于谁 —— 树形结构就白做了。
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.title = ""
        column.width = Self.sidebarWidth
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarOutline = outline
        return scroll
    }

    /// 一组内容的滚动视图。文档视图必须**翻转**：documentView 默认从左下角铺开，
    /// 内容超高时初始可见的是**底部**，用户得先滚才能看到顶部。
    private func makeGroupScrollView(_ content: NSStackView) -> NSScrollView {
        let container = FlippedContainerView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            // 【必须有 bottom】否则 container 在竖直方向是无约束的，
            // fittingSize.height 会退化成 0 —— 滚动区就成了一条细缝。
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = container
        // documentView 必须关掉 autoresizing：开着的话 AppKit 会自己生成一条
        // 「width == 0」的约束，和下面这条宽度约束同为必需优先级 → 互相冲突，
        // 结果文档视图宽度被钉成 0、整页空白（而且约束冲突在日志里不报）。
        container.translatesAutoresizingMaskIntoConstraints = false
        // documentView 宽度跟随可视宽度（只纵向滚动）。用 clip view 而不是
        // frameLayoutGuide —— 后者是 iOS UIScrollView 的 API，macOS 没有。
        container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    // MARK: - 分组切换

    /// 切到指定分组。侧栏点击与探针走**同一条路**，避免两套逻辑走偏。
    func selectSection(_ section: Section) {
        selectedSection = section
        for (s, view) in sectionContentViews {
            view.isHidden = (s != section)
        }
        guard let outline = sidebarOutline else { return }
        // 子条目的行号只在父项展开时才有意义 —— 先展开父项再问行号。
        if let parent = section.parent {
            outline.expandItem(parent)
        }
        let row = outlineRow(for: section)
        guard row >= 0, outline.selectedRow != row else { return }
        isSwitchingSection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isSwitchingSection = false
    }

    /// 条目在侧栏里的行号。问不到时返回 -1（= 别动选中行）。
    ///
    /// 优先问 outline —— 它知道当前的展开状态（父项收起时子条目的行号不存在）。
    /// 兜底按 allCases 序号取，但**必须校验那一行确实是它**：宁可不同步选中行，
    /// 也不能选错行 —— 选错行会让侧栏高亮停在别的分组上，
    /// 用户点了「忽略的应用」却看到「通用」被选中。
    private func outlineRow(for section: Section) -> Int {
        let row = sidebarOutline.row(forItem: section)
        if row >= 0 { return row }
        let fallback = Section.allCases.firstIndex(of: section) ?? 0
        guard let item = sidebarOutline.item(atRow: fallback) else { return -1 }
        return (item as? Section) == section ? fallback : -1
    }

    // MARK: - 侧栏数据源 / 委托

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        // item 为 nil = 根节点 → 顶层分组；有 item = 该条目的子条目。
        guard let section = item as? Section else { return Section.topLevel.count }
        return section.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let section = item as? Section else { return Section.topLevel[index] }
        return section.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Section)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let section = item as? Section else { return nil }
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 8)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: section.symbolName,
                              accessibilityDescription: section.title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: section.title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)

        if section == .ignoredApps {
            // 徽标：清单长度会变，放在侧栏就不用点进去才知道有几条。
            let badge = NSTextField(
                labelWithString: "\(Preferences.shared.ignoredBundleIdentifiers.count)")
            badge.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            badge.textColor = .secondaryLabelColor
            badge.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            row.addArrangedSubview(badge)
            sidebarCountBadge = badge
        }
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSwitchingSection,
              let outline = notification.object as? NSOutlineView,
              outline.selectedRow >= 0,
              let section = outline.item(atRow: outline.selectedRow) as? Section else { return }
        selectSection(section)
    }

    // MARK: - 各分组内容

    private func buildSectionContent(_ section: Section) -> NSStackView {
        switch section {
        case .shortcuts: return buildShortcutsSection()
        case .ignoredApps: return buildIgnoredAppsSection()
        case .general: return buildGeneralSection()
        case .advanced: return buildAdvancedSection()
        case .about: return buildAboutSection()
        }
    }

    /// 分组内容栈。垂直排列、组内间距 12pt。
    private func makeGroupStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        // 必须关掉 autoresizing：开着的话 stack 会留一条「width == 0」的
        // autoresizing 约束，和「贴住容器四边」的 Auto Layout 约束打架 ——
        // 结果整个分组宽度被钉成 0、滚动区一片空白。
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// 分区小标题。
    private func makeSectionTitle(_ text: String, size: CGFloat = 13) -> NSTextField {
        let title = NSTextField(labelWithString: text)
        title.font = NSFont.systemFont(ofSize: size, weight: .semibold)
        return title
    }

    /// 灰色说明文字。
    private func makeHint(_ text: String) -> NSTextField {
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 400
        return hint
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    /// 快捷键组：截图快捷键 + 「忽略的应用」摘要行。
    ///
    /// 摘要行只报数量并给一个跳转按钮 —— **清单本身不在这里**（在子面板
    /// `buildIgnoredAppsSection`）。理由见 `Section` 的注释：清单长度不可控，
    /// 放在主页面就会把主页面长度和清单长度绑在一起。
    private func buildShortcutsSection() -> NSStackView {
        let root = makeGroupStack()
        root.addArrangedSubview(makeSectionTitle("全局快捷键"))

        regionButton = makeRecorderButton(action: #selector(recordRegion))
        windowButton = makeRecorderButton(action: #selector(recordWindow))
        root.addArrangedSubview(makeRow(label: "区域截图", button: regionButton))
        root.addArrangedSubview(makeRow(label: "窗口截图", button: windowButton))

        root.addArrangedSubview(makeHint(
            "点击按钮后按下新的组合键，按 Esc 取消。组合键需包含 ⌘ 或 ⌃ —— 只用 ⇧ / ⌥ 会抢掉系统范围内的正常打字。"))

        root.addArrangedSubview(makeSeparator())
        root.addArrangedSubview(makeIgnoredAppsSummaryRow())
        root.addArrangedSubview(makeHint("这些应用在前台时，截图快捷键不触发。"))
        return root
    }

    /// 「忽略的应用」子面板：清单 + 添加按钮。
    ///
    /// 清单搬到这里（2026-11-12 步骤②）。这里才是清单的家 ——
    /// 快捷键页只留一行摘要，于是「改一个快捷键」不需要滚过一屏应用名。
    private func buildIgnoredAppsSection() -> NSStackView {
        let root = makeGroupStack()
        root.addArrangedSubview(makeSectionTitle("忽略的应用"))
        root.addArrangedSubview(makeHint("这些应用处于前台时，截图快捷键不会触发。"))

        ignoredAppsBox = NSStackView()
        ignoredAppsBox.orientation = .vertical
        ignoredAppsBox.alignment = .leading
        ignoredAppsBox.spacing = 6
        ignoredAppsBox.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        root.addArrangedSubview(ignoredAppsBox)

        let addAppButton = NSButton(title: "＋ 添加应用程序…",
                                    target: self, action: #selector(addIgnoredApp))
        addAppButton.bezelStyle = .rounded
        root.addArrangedSubview(addAppButton)

        root.addArrangedSubview(makeHint(
            "受 macOS 限制，被拦截的按键不会转发给该应用（默认组合 ⌃⌘A / ⌃⌘W 很冷门，一般无影响）。"
            + "支持 bundle id 前缀规则，以 * 结尾。"))
        return root
    }

    /// 「忽略的应用」摘要行：标签 + 计数 + 「设置…」跳转按钮。
    private func makeIgnoredAppsSummaryRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let label = NSTextField(labelWithString: "忽略的应用")
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true
        row.addArrangedSubview(label)

        let count = NSTextField(
            labelWithString: Self.ignoredAppsCountText(
                Preferences.shared.ignoredBundleIdentifiers.count))
        count.font = NSFont.systemFont(ofSize: 12)
        count.textColor = .secondaryLabelColor
        ignoredAppsSummaryCountLabel = count
        row.addArrangedSubview(count)

        let settingsButton = NSButton(title: "设置…",
                                      target: self, action: #selector(showIgnoredAppsPanel))
        settingsButton.bezelStyle = .rounded
        row.addArrangedSubview(settingsButton)
        return row
    }

    /// 清单条数的文案。0 条说「未设置」而不是「0 个应用」——
    /// 后者读起来像「配了 0 个」，前者才说得清是**没配**。
    private static func ignoredAppsCountText(_ count: Int) -> String {
        count == 0 ? "未设置" : "\(count) 个应用"
    }

    /// 「设置…」按钮：跳到「忽略的应用」子面板。
    @objc private func showIgnoredAppsPanel() {
        selectSection(.ignoredApps)
    }

    /// 通用组：启动、截图历史、状态栏图标、选区、打码。
    private func buildGeneralSection() -> NSStackView {
        let root = makeGroupStack()

        // ── 启动 ──
        root.addArrangedSubview(makeSectionTitle("启动"))
        launchAtLoginBox = NSButton(checkboxWithTitle: "开机自动启动（登录后在后台待命）",
                                    target: self, action: #selector(launchAtLoginToggled(_:)))
        root.addArrangedSubview(launchAtLoginBox)
        root.addArrangedSubview(makeHint(
            "AISnap 常驻状态栏、不占 Dock，截图靠全局快捷键 —— 所以它需要一直在后台待命。"
            + "打开这个开关就不用每次重启后手动启动。"))
        root.addArrangedSubview(makeSeparator())

        // ── 截图历史 ──
        root.addArrangedSubview(makeSectionTitle("截图历史"))
        recordHistoryBox = NSButton(checkboxWithTitle: "保留截图历史（含没有保存的）",
                                    target: self, action: #selector(recordHistoryToggled(_:)))
        root.addArrangedSubview(recordHistoryBox)
        root.addArrangedSubview(makeHint(
            "开启后每次截图都会在原图存一份，最多保留最近 \(CaptureHistory.maximumEntries) 张，"
            + "可以在「截图历史」窗口里重新编辑或清理。"
            + "截图常含敏感内容，不需要就到状态栏菜单 →「截图历史…」里删掉，或在这里关掉。"))
        root.addArrangedSubview(makeSeparator())

        // ── 状态栏图标 ──
        root.addArrangedSubview(makeSectionTitle("状态栏图标"))
        trayLeftPopup = makeTrayPopup()
        trayRightPopup = makeTrayPopup()
        trayMiddlePopup = makeTrayPopup()
        root.addArrangedSubview(makeTrayRow(label: "左键", popup: trayLeftPopup))
        root.addArrangedSubview(makeTrayRow(label: "右键", popup: trayRightPopup))
        root.addArrangedSubview(makeTrayRow(label: "中键", popup: trayMiddlePopup))
        root.addArrangedSubview(makeHint(
            "分别绑定单击状态栏图标的动作，修改即时生效。至少保留一个按键为「弹出菜单」，"
            + "否则将无法从状态栏打开偏好设置、截图历史或退出。"))
        root.addArrangedSubview(makeSeparator())

        // ── 选区 ──
        root.addArrangedSubview(makeSectionTitle("选区"))
        snapToWindowsBox = NSButton(checkboxWithTitle: "选区边缘自动吸附到窗口（8 点内生效）",
                                    target: self,
                                    action: #selector(snapToWindowsToggled(_:)))
        snapToWindowsBox.state = Preferences.shared.snapSelectionToWindows ? .on : .off
        root.addArrangedSubview(snapToWindowsBox)
        root.addArrangedSubview(makeHint(
            "拖拽选区时，选区四边会自动贴到附近窗口的边框上，方便整窗截取；"
            + "被贴住的窗口会高亮描边。想框歪随时可以 —— 只在 8 点内生效。"))
        root.addArrangedSubview(makeSeparator())

        // ── 打码 ──
        root.addArrangedSubview(makeSectionTitle("打码"))
        redactionStrengthSlider = NSSlider(value: Preferences.shared.redactionStrength,
                                           minValue: 0.5, maxValue: 3.0,
                                           target: self,
                                           action: #selector(redactionStrengthChanged(_:)))
        // 0.5 起步、1.0 是缺省：给两个刻度点让「默认在哪」看得见
        redactionStrengthSlider.allowsTickMarkValuesOnly = false
        redactionStrengthSlider.isContinuous = true
        redactionStrengthLabel = NSTextField(labelWithString: Self.strengthText(
            Preferences.shared.redactionStrength))
        redactionStrengthLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let strengthRow = NSStackView(views: [
            NSTextField(labelWithString: "强度"),
            redactionStrengthSlider,
            redactionStrengthLabel,
        ])
        strengthRow.orientation = .horizontal
        strengthRow.spacing = 12
        redactionStrengthSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(strengthRow)
        root.addArrangedSubview(makeHint(
            "马赛克与模糊共用这一个强度：1.0× = 默认（12 点块 / 半径），对小图可调细到 0.5×，"
            + "高分屏大图可调粗到 3.0×。只影响之后新画的打码，已画好的不变。"))
        return root
    }

    /// 高级组：更新清单地址与说明。
    ///
    /// 为什么单独一组（2026-11-12）：清单地址是一个 JSON 文件的 URL，
    /// 填它的人得先懂「发布协议」这套概念 —— 普通用户不该为了更新先理解它。
    /// 日常能用的「立即检查更新」放在「关于」组，默认界面就够用。
    private func buildAdvancedSection() -> NSStackView {
        let root = makeGroupStack()
        root.addArrangedSubview(makeSectionTitle("更新清单"))

        let urlRow = NSStackView()
        urlRow.orientation = .horizontal
        urlRow.spacing = 12
        let urlLabel = NSTextField(labelWithString: "清单地址")
        urlLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        urlRow.addArrangedSubview(urlLabel)

        feedURLField = NSTextField(string: "")
        feedURLField.placeholderString = "https://…/latest.json（留空则不检查）"
        feedURLField.font = NSFont.systemFont(ofSize: 12)
        feedURLField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        feedURLField.target = self
        feedURLField.action = #selector(feedURLChanged(_:))
        urlRow.addArrangedSubview(feedURLField)
        root.addArrangedSubview(urlRow)

        autoCheckBox = NSButton(checkboxWithTitle: "启动时自动检查更新",
                                target: self, action: #selector(autoCheckToggled(_:)))
        root.addArrangedSubview(autoCheckBox)

        root.addArrangedSubview(makeHint(
            "清单是一个 JSON 文件：{\"version\":\"1.2.0\", \"downloadURL\":\"https://…\", \"notes\":\"…\"}。\n"
            + "目前只会提示并跳到下载页，不会自动替换应用本身 —— 那需要先做代码签名与公证。"))
        return root
    }

    /// 关于组：版本、立即检查更新、恢复默认。
    ///
    /// 「恢复默认」放在这里而不是页面底部：它是低频且不可逆的操作，
    /// 不该占首屏（原来它在长页面最底下，出事时根本够不着）。
    private func buildAboutSection() -> NSStackView {
        let root = makeGroupStack()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionLabel = NSTextField(labelWithString: version.map { "AISnap \($0)" } ?? "AISnap")
        versionLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        root.addArrangedSubview(versionLabel)

        let checkRow = NSStackView()
        checkRow.orientation = .horizontal
        checkRow.spacing = 8
        checkRow.addArrangedSubview(NSButton(title: "立即检查更新",
                                             target: self, action: #selector(checkNow)))
        root.addArrangedSubview(checkRow)

        root.addArrangedSubview(makeSeparator())
        root.addArrangedSubview(makeSectionTitle("恢复默认", size: 12))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(NSButton(title: "恢复默认快捷键",
                                              target: self, action: #selector(resetHotkeys)))
        buttonRow.addArrangedSubview(NSButton(title: "恢复全部默认设置",
                                              target: self, action: #selector(resetAll)))
        root.addArrangedSubview(buttonRow)
        return root
    }

    /// 按**固定**尺寸设置窗口，**钳到屏幕可视区内**。
    ///
    /// 为什么固定（2026-11-12 改版）：原来窗口高度 = 内容高度（上限为屏幕可视高 −80），
    /// 而内容 1162pt > 上限 970~1042pt —— 于是**开窗即满屏 + 永远带滚动条**。
    /// 高度固定后，内容超出由内容区自己滚，窗口尺寸与内容彻底解耦。
    private func fitWindowToContent() {
        guard let window = window else { return }
        let visibleHeight = visibleHeightProvider?() ?? screenVisibleHeight(for: window)
        window.setContentSize(NSSize(width: Self.preferredContentWidth,
                                     height: Self.contentHeight(visibleHeight: visibleHeight)))
    }

    /// 窗口内容高度 = min(目标高, 钳制上限)。
    ///
    /// 抽成纯函数是为了让探针能**注入固定高度**断言：目标高是常量、
    /// 钳制上限随屏幕变 —— 两边都读本机的话，「窗口多高」在不同机器上结论就不同，
    /// 红灯常态化 = 回归网失效（O2 的教训）。
    static func contentHeight(visibleHeight: CGFloat) -> CGFloat {
        min(preferredContentHeight, clampMaxHeight(visibleHeight: visibleHeight))
    }

    /// 窗口高度上限 = 屏幕可视高度 − 80，且不小于 320。
    ///
    /// **−80 的构成（2026-11-11 实测，本机 macOS 27）**：标题栏 **28**
    /// （窗口 frame 与 contentRect 的高度差）+ 上下各 **26** 的呼吸边 = 80。
    /// visibleFrame 已排除 Dock 与菜单栏，所以这里不再叠加系统边距。
    static func clampMaxHeight(visibleHeight: CGFloat) -> CGFloat {
        max(320, visibleHeight - 80)
    }

    /// 窗口**实际所在**屏的可视高度。
    ///
    /// 用 `window.screen` 而不是 `NSScreen.main`：后者是「当前持键盘焦点的屏幕」，
    /// 设置窗开在副屏时会被钳到主屏的高度 —— 副屏比主屏矮时窗口就掉出了
    /// 副屏可视区，正是 E06 要修的那个 bug 的镜像。
    private func screenVisibleHeight(for window: NSWindow) -> CGFloat {
        Self.resolveVisibleHeight(
            windowScreenHeight: window.screen?.visibleFrame.height,
            mainScreenHeight: NSScreen.main?.visibleFrame.height)
    }

    /// 屏幕高度的选择规则（纯函数，探针可断言）。
    ///
    /// 规则只有一条：**优先用窗口实际所在的那块屏**；窗口还没落在任何屏上
    /// （构造阶段、离屏探针）才退回主屏；两块都没有就用兜底值。
    ///
    /// 抽成纯函数的原因：窗口高度现在是**固定**的（见 `contentHeight(visibleHeight:)`），
    /// 只有屏特别矮时才会碰到钳制 —— 想验证「取的是哪块屏」就不能依赖真实机器的
    /// 屏幕高度（这台机器全是大屏 → 永远碰不到钳制 → 断言恒真 = 没有断言）。
    static func resolveVisibleHeight(windowScreenHeight: CGFloat?,
                                     mainScreenHeight: CGFloat?,
                                     fallback: CGFloat = 900) -> CGFloat {
        windowScreenHeight ?? mainScreenHeight ?? fallback
    }

    private func makeRecorderButton(action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .rounded
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        return button
    }

    private func makeRow(label: String, button: NSButton) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let text = NSTextField(labelWithString: label)
        text.widthAnchor.constraint(equalToConstant: 80).isActive = true
        row.addArrangedSubview(text)
        row.addArrangedSubview(button)
        return row
    }

    /// 滚动容器的内容宿主。**必须翻转**：documentView 默认从左下角铺开，
    /// 内容超高时初始可见的是**底部**，用户得先滚才能看到顶部。
    private final class FlippedContainerView: NSView {
        override var isFlipped: Bool { true }
    }

    /// 让窗口显示在已存偏好上。
    private func refreshFromPreferences() {
        regionButton.title = Preferences.shared.regionCaptureHotkey.displayString
        windowButton.title = Preferences.shared.windowCaptureHotkey.displayString
        feedURLField.stringValue = Preferences.shared.updateFeedURL
        autoCheckBox.state = Preferences.shared.automaticallyChecksForUpdates ? .on : .off
        recordHistoryBox.state = Preferences.shared.recordHistory ? .on : .off
        rebuildIgnoredAppsList()
        syncTrayPopupsToPreferences()
        refreshLaunchAtLogin()
    }

    /// 内容行数变化后重算窗口高度（与 launchAtLoginToggled 里同一手法）。
    /// 统一走 fitWindowToContent —— 那里有尺寸与屏幕高度钳制的全部说明。
    private func fitWindow() {
        fitWindowToContent()
    }

    @objc private func recordHistoryToggled(_ sender: NSButton) {
        Preferences.shared.recordHistory = (sender.state == .on)
    }

    @objc private func snapToWindowsToggled(_ sender: NSButton) {
        Preferences.shared.snapSelectionToWindows = (sender.state == .on)
    }

    /// 打码强度滑杆：即时写回偏好，数值标签同步。
    /// 马赛克/模糊在**绘制时**读偏好，所以不需要刷新已存在的对象（见打码段提示文案）。
    @objc private func redactionStrengthChanged(_ sender: NSSlider) {
        let value = (sender.doubleValue * 10).rounded() / 10   // 步进 0.1，防出现 1.0000001×
        Preferences.shared.redactionStrength = value
        redactionStrengthLabel.stringValue = Self.strengthText(value)
    }

    private static func strengthText(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    // MARK: - 忽略的应用程序

    /// 按偏好重建忽略列表的行。整体重建最省心：增删之后不必手工对齐行与数据。
    private func rebuildIgnoredAppsList() {
        ignoredAppsBox.subviews.forEach { $0.removeFromSuperview() }

        let ids = Preferences.shared.ignoredBundleIdentifiers
        // 两处计数都要跟着变：快捷键页的摘要行、侧栏条目的徽标。
        // 徽标可能还没被创建（侧栏视图懒加载），那就等它创建时按当前偏好填。
        ignoredAppsSummaryCountLabel?.stringValue = Self.ignoredAppsCountText(ids.count)
        sidebarCountBadge?.stringValue = "\(ids.count)"

        if ids.isEmpty {
            let empty = NSTextField(labelWithString: "（无）所有应用中快捷键都正常生效")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            ignoredAppsBox.addArrangedSubview(empty)
            return
        }

        for id in ids {
            ignoredAppsBox.addArrangedSubview(makeIgnoredAppRow(bundleID: id))
        }
    }

    private func makeIgnoredAppRow(bundleID: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let name = displayName(forBundleID: bundleID)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(nameLabel)

        // 显示名与 bundle id 不同时，把灰色 id 附在后面，方便确认选对了应用
        if name != bundleID {
            let idLabel = NSTextField(labelWithString: bundleID)
            idLabel.font = NSFont.systemFont(ofSize: 10)
            idLabel.textColor = .secondaryLabelColor
            idLabel.lineBreakMode = .byTruncatingTail
            idLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(idLabel)
        }

        let remove = NSButton(title: "－", target: self, action: #selector(removeIgnoredApp(_:)))
        remove.bezelStyle = .rounded
        remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
        remove.toolTip = "移除"
        row.addArrangedSubview(remove)

        row.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        return row
    }

    /// 用 bundle id 反查应用显示名；查不到（应用已卸载/是前缀规则）就直接显示 id。
    private func displayName(forBundleID id: String) -> String {
        if id.hasSuffix("*") { return id }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
              let bundle = Bundle(url: url) else { return id }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty { return display }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return id
    }

    @objc private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.title = "选择要忽略快捷键的应用"
        panel.message = "可多选。选中的应用处于前台时，截图全局快捷键不会触发。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.application]
        guard let window = window else { return }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self else { return }

            var ids = Preferences.shared.ignoredBundleIdentifiers
            var unreadable: [String] = []
            for appURL in panel.urls {
                guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
                    unreadable.append(appURL.deletingPathExtension().lastPathComponent)
                    continue
                }
                if !ids.contains(bundleID) { ids.append(bundleID) }
            }
            Preferences.shared.ignoredBundleIdentifiers = ids
            self.rebuildIgnoredAppsList()
            self.fitWindow()

            if !unreadable.isEmpty {
                let alert = NSAlert()
                alert.messageText = "部分应用无法识别"
                alert.informativeText = "以下应用读不到 bundle identifier，未加入列表：\n"
                    + unreadable.joined(separator: "、")
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func removeIgnoredApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var ids = Preferences.shared.ignoredBundleIdentifiers
        ids.removeAll { $0 == id }
        Preferences.shared.ignoredBundleIdentifiers = ids
        rebuildIgnoredAppsList()
        fitWindow()
    }

    // MARK: - 状态栏按键动作

    private func makeTrayPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for action in TrayClickAction.allCases {
            let item = NSMenuItem(title: action.displayName, action: nil, keyEquivalent: "")
            item.representedObject = action.rawValue
            popup.menu?.addItem(item)
        }
        popup.target = self
        popup.action = #selector(trayActionChanged(_:))
        return popup
    }

    private func makeTrayRow(label: String, popup: NSPopUpButton) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        let text = NSTextField(labelWithString: label)
        text.widthAnchor.constraint(equalToConstant: 80).isActive = true
        row.addArrangedSubview(text)
        row.addArrangedSubview(popup)
        return row
    }

    private func syncTrayPopupsToPreferences() {
        select(trayLeftPopup, action: Preferences.shared.trayLeftAction)
        select(trayRightPopup, action: Preferences.shared.trayRightAction)
        select(trayMiddlePopup, action: Preferences.shared.trayMiddleAction)
    }

    private func select(_ popup: NSPopUpButton, action: TrayClickAction) {
        guard let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == action.rawValue
        }) else { return }
        popup.select(item)
    }

    private func selectedAction(_ popup: NSPopUpButton) -> TrayClickAction {
        guard let raw = popup.selectedItem?.representedObject as? String,
              let action = TrayClickAction(rawValue: raw) else { return .menu }
        return action
    }

    @objc private func trayActionChanged(_ sender: NSPopUpButton) {
        let left = selectedAction(trayLeftPopup)
        let right = selectedAction(trayRightPopup)
        let middle = selectedAction(trayMiddlePopup)

        // 兜底守卫：三个键必须留一个「弹出菜单」，否则状态栏里再也到不了偏好/历史/退出。
        // 拒绝本次修改：不落盘，并把控件回滚为已存值。
        guard [left, right, middle].contains(.menu) else {
            syncTrayPopupsToPreferences()
            statusLabel.stringValue = Self.menuGuardMessage
            statusLabel.textColor = .systemOrange
            statusLabel.isHidden = false
            fitWindow()
            return
        }

        Preferences.shared.trayLeftAction = left
        Preferences.shared.trayRightAction = right
        Preferences.shared.trayMiddleAction = middle
        // 若此前显示的是本功能的守卫告警，现在状态合法了，收掉它；
        // 热键注册等其它告警按文案区分，不误清。
        if statusLabel.stringValue == Self.menuGuardMessage {
            statusLabel.isHidden = true
        }
    }

    private static let menuGuardMessage =
        "至少保留一个按键为「弹出菜单」，否则将无法打开偏好设置与退出。"

    // MARK: - 开机启动

    /// 以**系统状态**回写控件。不能用「用户点了什么」当作显示状态：
    /// 注册可能失败、也可能需要用户去系统设置里批准，那时勾选框不能显示成已设置 ——
    /// 否则关掉窗口再打开会看到它自己变回去了，用户只会觉得这个开关坏了。
    private func refreshLaunchAtLogin() {
        launchAtLoginBox.state = (LaunchAtLogin.status == .enabled) ? .on : .off
        launchAtLoginBox.isEnabled = (LaunchAtLogin.status != .unavailable)
        if LaunchAtLogin.status == .unavailable {
            launchAtLoginBox.toolTip = "需要从「应用程序」里的 AISnap 使用"
        }
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        if let problem = LaunchAtLogin.setEnabled(sender.state == .on) {
            statusLabel.stringValue = problem
            statusLabel.textColor = .systemOrange
            statusLabel.isHidden = false
        }
        refreshLaunchAtLogin()
        fitWindow()
    }

    // MARK: - 更新设置

    @objc private func feedURLChanged(_ sender: NSTextField) {
        Preferences.shared.updateFeedURL =
            sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func autoCheckToggled(_ sender: NSButton) {
        Preferences.shared.automaticallyChecksForUpdates = (sender.state == .on)
    }

    @objc private func checkNow() {
        // 先落盘再检查：用户可能刚改完地址就直接点检查，不等焦点离开输入框
        Preferences.shared.updateFeedURL =
            feedURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onCheckForUpdates?()
    }

    private func showProblems(_ problems: [String]) {
        statusLabel.stringValue = problems.joined(separator: "\n")
        statusLabel.isHidden = problems.isEmpty
        statusLabel.textColor = problems.isEmpty ? .secondaryLabelColor : .systemOrange
        if !problems.isEmpty {
            fitWindow()
        }
    }

    // MARK: - 录键

    @objc private func recordRegion() { startRecording(.region) }
    @objc private func recordWindow() { startRecording(.window) }

    private func startRecording(_ target: RecordingTarget) {
        stopRecording()                     // 防止重复点击装出多个键盘监视器
        recordingTarget = target
        statusLabel.isHidden = true

        let active = (target == .region) ? regionButton : windowButton
        active?.title = "按下新的组合键…"

        // 本地监视器而不是全局：录制期间本应用是前台，本地监视器足够，
        // 而且它**能拦截**事件（全局监视器只能旁观，退格键之类会漏给下层控件）。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleRecordedKey(event)
            return nil                      // 吞掉这次按键，不让它传给窗口
        }
    }

    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        recordingTarget = nil
        refreshFromPreferences()            // 取消时把按钮标题还原成实际生效的值
    }

    private func handleRecordedKey(_ event: NSEvent) {
        guard let target = recordingTarget else { return }

        // Esc 取消
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return
        }

        let modifiers = HotkeyConfig.carbonModifiers(from: event.modifierFlags)
        let config = HotkeyConfig(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)

        // 走到这里的只可能是"完整但不可用的组合"（如 ⇧A、⌥A）——
        // 纯修饰键根本不会产生 keyDown（那是 flagsChanged），所以不存在
        // "用户正在按修饰键、我们继续等"的情形。原先的注释写成那样是错的。
        guard config.isUsable else {
            statusLabel.stringValue = "组合键需包含 ⌘ 或 ⌃（只用 ⇧ / ⌥ 会抢掉正常打字），且需为字母、数字或常用符号。"
            statusLabel.isHidden = false
            return
        }

        if HotkeyConfig.systemScreenshotCombos.contains(config) {
            statusLabel.stringValue = "\(config.displayString) 是系统截图的快捷键，请换一个组合。"
            statusLabel.isHidden = false
            return
        }

        switch target {
        case .region: Preferences.shared.regionCaptureHotkey = config
        case .window: Preferences.shared.windowCaptureHotkey = config
        }

        stopRecording()
        showProblems(onHotkeysChanged?() ?? [])
    }

    // MARK: - 恢复默认

    @objc private func resetHotkeys() {
        Preferences.shared.regionCaptureHotkey = Preferences.Defaults.regionCaptureHotkey
        Preferences.shared.windowCaptureHotkey = Preferences.Defaults.windowCaptureHotkey
        refreshFromPreferences()
        showProblems(onHotkeysChanged?() ?? [])
    }

    @objc private func resetAll() {
        Preferences.shared.resetToDefaults()
        refreshFromPreferences()
        showProblems(onHotkeysChanged?() ?? [])
        // 说明影响范围：已打开的标注窗口里控件仍持有旧值，一动就会写回偏好，
        // 所以不做「立即全部生效」的假象。
        statusLabel.stringValue = "已恢复默认设置。线宽、颜色、线型、箭头样式、调色板、水印与默认工具均已回出厂值；\n已打开的标注窗口不受影响，下次截图时生效。"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
    }

    /// 供 AppDelegate 调用：窗口显示前先同步一次已存值。
    func present() {
        stopRecording()
        // 每次都重新读：开机启动的真实状态在系统手里，用户可能在
        // 「系统设置 → 通用 → 登录项与扩展」里改过，窗口不能显示上次的旧值
        refreshFromPreferences()
        showProblems([])
        // 忽略列表可能在窗口关闭期间被（未来的）其他入口改动，重新按尺寸摆一次
        fitWindow()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
