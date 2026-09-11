import Cocoa

/// 标注窗口 — 包含工具栏和标注画布，右侧附带 Layer B 调试面板
class AnnotationWindow: NSWindow {
    private var annotationView: AnnotationView!
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var colorButtonContainer: NSView!
    /// 当前调色板下标。初值取自偏好，改动时立刻写回（见 Preferences）。
    private var paletteIndex: Int = Preferences.shared.paletteIndex {
        didSet {
            guard paletteIndex != oldValue else { return }
            Preferences.shared.paletteIndex = paletteIndex
        }
    }
    private var watermarkField: NSTextField!
    private var lineWidthLabel: NSTextField!

    /// 工具栏实际排布出来的内容宽度（在 `createToolbar` 末尾由布局游标写入）。
    /// 窗口宽度据此决定，而不是用硬编码常量 —— 否则新增控件会被静默裁掉。
    private var toolbarContentWidth: CGFloat = 0

    /// 工具栏顶部那条通栏分隔线，窗口最终宽度确定后需要跟着调整。
    private var toolbarTopSeparator: NSBox?

    /// 工具栏挂在画布上方还是下方。
    ///
    /// 默认在下方（`origin.y = 选区底边 − 工具栏高度`）。但选区贴屏幕最底部时
    /// 那个值是负的、整条工具栏会沉出屏，于是翻到画布上方 ——
    /// 这样画布仍精确压在选区上，只是工具栏换了一侧。判定见 `AnchoredPlacement`。
    private var toolbarAtTop = false

    // MARK: 调试面板（默认隐藏，⌘D 开关）
    //
    // 视图一开始就建好、只是隐藏着：打开时不必重建，也不会因为"隐藏时干脆不建"
    // 而让 annotationView.debugImageView 为 nil。
    private weak var containerView: NSView?
    private weak var toolbarView: NSView?
    private var debugPanelView: NSImageView?
    private var debugLabelView: NSTextField?
    private var canvasWidth: CGFloat = 0
    private var debugPanelWidth: CGFloat = 0

    /// 就地编辑模式下要覆盖的选区（AppKit 屏幕坐标）。非 nil 时窗口不允许被居中搬走。
    private var anchoredRect: NSRect?

    /// 关闭时回调（AppDelegate 用它把冻结的覆盖层收掉）。
    var onClose: (() -> Void)?

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    /// 取色器取到颜色：把 HEX 复制到剪贴板并提示。
    ///
    /// **顺带清掉调色板按钮的选中边框**：那些按钮用边框表示"当前用的是哪个颜色"，
    /// 而取来的颜色多半不在调色板里 —— 不清的话界面会指着 A 色、实际用的是 B 色。
    /// （当前颜色本身由画布在调用这里之前就写好了。）
    func didPickColor(hex: String) {
        for btn in colorButtons {
            btn.layer?.borderColor = NSColor.clear.cgColor
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        flashHUD("已取色 \(hex)　已复制")
    }

    /// 区域截图「就地编辑」模式下，画布精确覆盖在刚才的选区上。
    ///
    /// - Parameter anchor: 选区在 AppKit 屏幕坐标下的矩形；传 nil 则按普通方式居中开窗
    ///   （窗口截图走这条路）。
    init(image: NSImage, anchor: NSRect? = nil) {
        let imageSize = image.size
        let toolbarHeight: CGFloat = 48

        // 右侧 Layer B 调试面板的几何：尺寸按画布的一半算，但**默认不显示、也不占窗口宽度**。
        //
        // 它是开发期工具（实时显示命中缓冲区的唯一颜色图），普通用户看到右侧一块
        // 莫名的深色分屏只会困惑。评审提的"默认隐藏 + ⌘D 开关"就是这个意思：
        // 视图照建、随时可以打开，但默认不打扰人。
        let anchored = anchor
        let debugPanelScale: CGFloat = 0.5
        let debugPadding: CGFloat = 8

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let fitScale: CGFloat
        if anchored != nil {
            // 就地编辑：画布就是选区本身，不做任何缩放适配
            // （选区必然在屏幕内，而且它已经在屏幕上被用户看到过了，缩放会"跳"一下）
            fitScale = 1
        } else {
            let maxW = screenFrame.width * 0.9
            let maxH = screenFrame.height * 0.9 - toolbarHeight
            // 窗口的自然宽度不再包含调试面板 —— 它默认隐藏，不该占地方
            let naturalTotalW = imageSize.width
            fitScale = min(1.0, min(maxW / naturalTotalW, maxH / imageSize.height))
        }

        let canvasW = imageSize.width * fitScale
        let canvasH = imageSize.height * fitScale
        let debugWidth = canvasW * debugPanelScale
        let debugHeight = canvasH * debugPanelScale

        // 窗口内容宽度只算画布：调试面板默认隐藏，打开时再按需要撑宽
        let contentWidth = canvasW
        let contentHeight = canvasH + toolbarHeight

        let initialWidth = max(contentWidth, 400)

        // 就地编辑的落点：画布左下角钉在选区左下角、工具栏挂在画布某侧。
        // 具体挂哪一侧、以及贴屏幕边缘时怎么夹，都由 AnchoredPlacement 这个纯函数算 ——
        // 那几条边界在离屏进程里走不到（NSScreen.main 是 nil），抽出去才能逐个验证。
        let placement: AnchoredPlacement.Result?
        let initialOrigin: NSPoint
        if let anchor = anchored {
            let result = AnchoredPlacement.compute(
                anchor: anchor,
                windowSize: NSSize(width: initialWidth, height: contentHeight),
                toolbarHeight: toolbarHeight,
                screenFrame: NSScreen.main?.frame ?? screenFrame)
            placement = result
            initialOrigin = result.origin
        } else {
            placement = nil
            initialOrigin = NSPoint(x: screenFrame.midX - initialWidth / 2,
                                    y: screenFrame.midY - contentHeight / 2)
        }
        let toolbarAtTop = placement?.toolbarAtTop ?? false
        self.toolbarAtTop = toolbarAtTop
        // 画布在容器里的下边缘：工具栏在下方时画布从 toolbarHeight 起，
        // 工具栏翻到上方时画布从 0 起
        let canvasBottom = toolbarAtTop ? 0 : toolbarHeight

        super.init(
            contentRect: NSRect(origin: initialOrigin,
                                size: NSSize(width: initialWidth, height: contentHeight)),
            // 就地编辑用无边框：带标题栏会让 contentRect 比 frame 内缩，
            // 画布就没法精确对齐选区了
            styleMask: anchored == nil ? [.titled, .closable, .miniaturizable] : [.borderless],
            backing: .buffered,
            defer: false
        )

        self.title = "AISnap - 标注"
        self.isReleasedWhenClosed = false
        self.anchoredRect = anchored

        if anchored != nil {
            // 压在冻结覆盖层之上（覆盖层是 .statusBar + 1）
            self.level = .statusBar + 2
        }

        // 设置应用菜单栏
        setupMainMenu()

        let container = NSView(frame: NSRect(origin: .zero,
                                             size: NSSize(width: initialWidth,
                                                          height: contentHeight)))

        // 标注画布
        annotationView = AnnotationView(image: image)
        annotationView.frame = NSRect(x: 0, y: canvasBottom,
                                      width: canvasW, height: canvasH)
        if fitScale < 1.0 {
            annotationView.setBoundsSize(imageSize)
        }
        container.addSubview(annotationView)

        // Layer B 调试面板（建好但默认隐藏，见 ⌘D）
        let debugImageView = NSImageView(frame: NSRect(
            x: canvasW + debugPadding,
            y: canvasBottom + (canvasH - debugHeight),
            width: debugWidth,
            height: debugHeight
        ))
        debugImageView.imageScaling = .scaleProportionallyDown
        debugImageView.wantsLayer = true
        debugImageView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        debugImageView.layer?.borderColor = NSColor.separatorColor.cgColor
        debugImageView.layer?.borderWidth = 1
        debugImageView.layer?.cornerRadius = 4
        debugImageView.isHidden = true
        container.addSubview(debugImageView)

        annotationView.debugImageView = debugImageView

        let debugLabel = NSTextField(labelWithString: "Layer B (Debug)　⌘D 隐藏")
        debugLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        debugLabel.textColor = .secondaryLabelColor
        debugLabel.frame = NSRect(
            x: canvasW + debugPadding,
            y: canvasBottom + canvasH - debugHeight - 16,
            width: debugWidth,
            height: 14
        )
        debugLabel.alignment = .center
        debugLabel.isHidden = true
        container.addSubview(debugLabel)

        debugPanelView = debugImageView
        debugLabelView = debugLabel
        canvasWidth = canvasW
        debugPanelWidth = debugWidth + debugPadding
        containerView = container

        // 工具栏（可能挂在画布下方，也可能因为底部放不下而翻到上方）
        let toolbar = createToolbar(width: initialWidth, height: toolbarHeight)
        toolbar.frame.origin.y = toolbarAtTop ? canvasH : 0
        positionToolbarSeparator(for: toolbar)
        container.addSubview(toolbar)
        toolbarView = toolbar

        // 窗口宽度 = max(画布侧需求, 工具栏内容宽度 + 右侧留白)。
        //
        // 工具栏用绝对坐标排布、不换行不滚动，以前靠一个硬编码的最小宽度（1060）
        // 兜着；但工具栏内容已排到约 1050px，余量只有 10px，再加一个控件就会被
        // 静默裁掉（按钮直接消失，界面上没有任何提示）。改为按实际排布结果定宽。
        let requiredWidth = max(contentWidth, toolbarContentWidth + 8)
        if abs(requiredWidth - initialWidth) > 0.5 {
            resizeWindow(to: NSSize(width: requiredWidth, height: contentHeight),
                         container: container, toolbar: toolbar, screen: screenFrame)
        }

        self.contentView = container
    }

    /// 工具栏与画布之间那条分隔线。
    ///
    /// 它标的是"工具栏与画布的交界"，不是"工具栏的顶边"：工具栏在下方时画在顶边，
    /// 翻到上方时画在底边 —— 否则翻上去之后那条线会跑到窗口最外侧，看着像窗口边框。
    private func positionToolbarSeparator(for toolbar: NSView) {
        let y: CGFloat = toolbarAtTop ? 0 : toolbar.frame.height - 1
        toolbarTopSeparator?.frame = NSRect(x: 0, y: y,
                                            width: toolbar.frame.width, height: 1)
    }

    /// ⌘D：显示 / 隐藏 Layer B 调试面板。
    ///
    /// 面板的视图一直在容器里（只是隐藏），所以这里只改可见性与窗口宽度，
    /// 不重建任何东西。窗口宽度仍取「画布需求」与「工具栏需求」的较大者 ——
    /// 工具栏本来就比画布 + 面板宽时，开关面板不会改变窗口宽度。
    /// 开关前后保持窗口原点不动：这只是一个开发期开关，窗口跟着跳动很干扰。
    @objc func toggleDebugPanel() {
        guard let panel = debugPanelView, let label = debugLabelView,
              let container = containerView, let toolbar = toolbarView else { return }

        let willShow = panel.isHidden
        panel.isHidden = !willShow
        label.isHidden = !willShow
        (annotationView as AnnotationView?)?.needsDisplay = true

        let desired = canvasWidth + (willShow ? debugPanelWidth : 0)
        let newWidth = max(desired, toolbarContentWidth + 8)
        let contentHeight = contentView?.frame.height ?? frame.height
        guard abs(newWidth - frame.width) > 0.5 else { return }

        let originBefore = frame.origin
        resizeWindow(to: NSSize(width: newWidth, height: contentHeight),
                     container: container, toolbar: toolbar,
                     screen: NSScreen.main?.visibleFrame ?? frame)
        setFrameOrigin(originBefore)
    }

    /// 按工具栏的实际需求调整窗口宽度，并同步容器与工具栏的框架。
    private func resizeWindow(to size: NSSize, container: NSView,
                              toolbar: NSView, screen: NSRect) {
        setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)

        // 纵向位置由"挂在哪一侧"决定，**不能写成 y: 0** ——
        // 宽度调整发生在 init 里设好朝向之后，写死 0 会把"翻到上方"重置掉。
        // 这里只改宽度，高度不变，所以朝向不可能翻转，沿用已有的 toolbarAtTop 即可。
        let toolbarHeight = toolbar.frame.height
        toolbar.frame = NSRect(x: 0, y: toolbarAtTop ? annotationView.frame.height : 0,
                               width: size.width, height: toolbarHeight)
        positionToolbarSeparator(for: toolbar)

        if let anchor = anchoredRect {
            // 宽度变了要重算落点：同一个选区，窗口更宽时可能从"放得下"变成"要左移"
            let result = AnchoredPlacement.compute(
                anchor: anchor,
                windowSize: size,
                toolbarHeight: toolbarHeight,
                screenFrame: NSScreen.main?.frame ?? screen)
            setFrameOrigin(result.origin)
        } else {
            setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2,
                                   y: screen.midY - frame.height / 2))
        }
    }

    // MARK: - Main Menu Bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // ── AISnap 菜单 ──
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 AISnap", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "退出 AISnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ── 编辑菜单 ──
        let editMenu = NSMenu(title: "编辑")
        let undoItem = NSMenuItem(title: "撤销", action: #selector(undoAction), keyEquivalent: "z")
        undoItem.target = self
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "重做", action: #selector(redoAction), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        let deleteItem = NSMenuItem(title: "删除选中", action: #selector(deleteSelectedAction), keyEquivalent: "\u{8}")
        deleteItem.target = self
        editMenu.addItem(deleteItem)
        editMenu.addItem(NSMenuItem.separator())
        // 这两个在菜单里列出来主要是**可发现性**：快捷键本身在 AnnotationView.keyDown
        // 里也有一份实现，两条路都调用同一个方法。菜单若消费了事件，keyDown 就收不到，
        // 所以不会重复执行。
        let copyItem = NSMenuItem(title: "复制到剪贴板", action: #selector(copyImage), keyEquivalent: "c")
        copyItem.target = self
        editMenu.addItem(copyItem)
        let saveItem = NSMenuItem(title: "保存为文件…", action: #selector(saveImage), keyEquivalent: "s")
        saveItem.target = self
        editMenu.addItem(saveItem)
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // ── 帮助菜单 ──
        let helpMenu = NSMenu(title: "帮助")
        let helpItem = NSMenuItem(title: "使用帮助", action: #selector(showHelp), keyEquivalent: "/")
        helpItem.target = self
        helpMenu.addItem(helpItem)
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: - Toolbar

    private func createToolbar(width: CGFloat, height: CGFloat) -> NSView {
        let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSBox(frame: NSRect(x: 0, y: height - 1, width: width, height: 1))
        separator.boxType = .separator
        toolbar.addSubview(separator)
        toolbarTopSeparator = separator

        var xOffset: CGFloat = 8

        // ── 绘图工具（带文字标签）──
        // 宽度只是分组标签自己的框架宽度（标签文字左对齐，写宽了不会裁掉什么），
        // 写在这里是为了让"这一组占多宽"在代码里有个可见的数字。
        addGroupLabel("绘图工具", to: toolbar, at: xOffset, width: 430)
        for (i, item) in Self.toolbarTools.enumerated() {
            let btn = makeToolbarButton(title: item.title, tooltip: item.tip, at: xOffset, tag: i,
                                        action: #selector(toolButtonClicked(_:)))
            toolbar.addSubview(btn)
            toolButtons.append(btn)
            xOffset += btn.frame.width + 2
        }
        // 恢复上次使用的工具。tag 越界（比如版本更新后工具数变化）时回到第一个，
        // 而不是让工具栏处于「一个都没选中」的状态。
        let savedTag = Preferences.shared.lastToolTag
        let restoredTag = (savedTag >= 0 && savedTag < Self.toolbarTools.count) ? savedTag : 0
        annotationView.currentTool = Self.toolbarTools[restoredTag].tool
        updateToolButtonStates(selectedIndex: restoredTag)
        xOffset += 4

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 箭头样式 ──
        // 注：常被选中的是箭头工具，样式选择放在工具组旁边最顺手。
        addGroupLabel("箭头样式", to: toolbar, at: xOffset, width: 84)
        let arrowStylePopup = NSPopUpButton(
            frame: NSRect(x: xOffset, y: 12, width: 84, height: 24), pullsDown: false)
        arrowStylePopup.font = NSFont.systemFont(ofSize: 11)
        arrowStylePopup.addItems(withTitles: ArrowStyle.presetNames)
        arrowStylePopup.selectItem(at: ArrowStyle.allPresets
            .firstIndex(of: annotationView.currentArrowStyle) ?? 0)
        arrowStylePopup.toolTip = "选择箭头样式（双向 = 两端都有箭头）"
        arrowStylePopup.target = self
        arrowStylePopup.action = #selector(arrowStyleSelected(_:))
        toolbar.addSubview(arrowStylePopup)
        xOffset += 88

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 撤销/重做 ──
        addGroupLabel("编辑", to: toolbar, at: xOffset, width: 72)
        let undoBtn = makeToolbarButton(title: "撤销", tooltip: "撤销 (Cmd+Z)", at: xOffset, tag: 100,
                                         action: #selector(undoAction))
        toolbar.addSubview(undoBtn)
        xOffset += undoBtn.frame.width + 2

        let redoBtn = makeToolbarButton(title: "重做", tooltip: "重做 (Cmd+Shift+Z)", at: xOffset, tag: 101,
                                         action: #selector(redoAction))
        toolbar.addSubview(redoBtn)
        xOffset += redoBtn.frame.width + 2
        xOffset += 4

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 颜色 ──
        addGroupLabel("颜色", to: toolbar, at: xOffset, width: 160)
        let paletteBtn = makeToolbarButton(title: "换色", tooltip: "切换调色板", at: xOffset, tag: 200,
                                            action: #selector(cyclePalette))
        toolbar.addSubview(paletteBtn)
        xOffset += paletteBtn.frame.width + 4

        colorButtonContainer = NSView(frame: NSRect(x: xOffset, y: 0, width: 200, height: height))
        toolbar.addSubview(colorButtonContainer)
        rebuildColorButtons()
        xOffset += CGFloat(ColorPalette.allPalettes[paletteIndex].colors.count) * 30 + 4

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 线宽 ──
        addGroupLabel("线宽", to: toolbar, at: xOffset, width: 100)
        let lineWidthSlider = NSSlider(frame: NSRect(x: xOffset, y: 14, width: 70, height: 20))
        lineWidthSlider.minValue = 1
        lineWidthSlider.maxValue = 30
        lineWidthSlider.doubleValue = Double(annotationView.currentLineWidth)
        lineWidthSlider.target = self
        lineWidthSlider.action = #selector(lineWidthChanged(_:))
        lineWidthSlider.toolTip = "调节线条粗细 (1-30)"
        toolbar.addSubview(lineWidthSlider)

        lineWidthLabel = NSTextField(labelWithString: "\(Int(annotationView.currentLineWidth))px")
        lineWidthLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        lineWidthLabel.textColor = .secondaryLabelColor
        lineWidthLabel.frame = NSRect(x: xOffset + 72, y: 16, width: 32, height: 14)
        toolbar.addSubview(lineWidthLabel)
        xOffset += 108

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 线型 ──
        // 只作用于矩形/椭圆这类形状；箭头的线型由「箭头样式」预设携带，两处各管一套。
        addGroupLabel("线型", to: toolbar, at: xOffset, width: 76)
        let lineStylePopup = NSPopUpButton(
            frame: NSRect(x: xOffset, y: 12, width: 76, height: 24), pullsDown: false)
        lineStylePopup.font = NSFont.systemFont(ofSize: 11)
        lineStylePopup.addItems(withTitles: LineStyle.allCases.map(\.displayName))
        lineStylePopup.selectItem(at: LineStyle.allCases
            .firstIndex(of: annotationView.currentLineStyle) ?? 0)
        lineStylePopup.toolTip = "新建矩形/椭圆使用的线型（箭头请用「箭头样式」）"
        lineStylePopup.target = self
        lineStylePopup.action = #selector(lineStyleSelected(_:))
        toolbar.addSubview(lineStylePopup)
        xOffset += 80

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 贴纸 ──
        addGroupLabel("贴纸", to: toolbar, at: xOffset, width: 56)
        let stampPopup = NSPopUpButton(frame: NSRect(x: xOffset, y: 12, width: 56, height: 24), pullsDown: true)
        stampPopup.font = NSFont.systemFont(ofSize: 11)
        stampPopup.addItem(withTitle: "选择")
        for (_, display) in defaultStamps {
            stampPopup.addItem(withTitle: display)
        }
        stampPopup.toolTip = "选择表情贴纸，然后在画布上点击放置"
        stampPopup.target = self
        stampPopup.action = #selector(stampSelected(_:))
        toolbar.addSubview(stampPopup)
        xOffset += 62

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 水印 ──
        addGroupLabel("水印", to: toolbar, at: xOffset, width: 140)
        let wmToggle = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(watermarkToggled(_:)))
        wmToggle.frame = NSRect(x: xOffset, y: 14, width: 48, height: 20)
        wmToggle.state = annotationView.watermarkConfig.enabled ? .on : .off
        wmToggle.font = NSFont.systemFont(ofSize: 11)
        wmToggle.toolTip = "导出图片时叠加水印"
        toolbar.addSubview(wmToggle)
        xOffset += 50

        watermarkField = NSTextField(frame: NSRect(x: xOffset, y: 14, width: 72, height: 20))
        watermarkField.stringValue = annotationView.watermarkConfig.text
        watermarkField.font = NSFont.systemFont(ofSize: 11)
        watermarkField.placeholderString = "水印文本"
        watermarkField.toolTip = "输入水印文本内容"
        watermarkField.target = self
        watermarkField.action = #selector(watermarkTextChanged(_:))
        toolbar.addSubview(watermarkField)
        xOffset += 78

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 导出 ──
        addGroupLabel("导出", to: toolbar, at: xOffset, width: 110)
        let saveBtn = makeToolbarButton(title: "保存", tooltip: "保存为 PNG 文件", at: xOffset, tag: 300,
                                         action: #selector(saveImage))
        toolbar.addSubview(saveBtn)
        xOffset += saveBtn.frame.width + 2

        let copyBtn = makeToolbarButton(title: "复制", tooltip: "复制到剪贴板", at: xOffset, tag: 301,
                                         action: #selector(copyImage))
        toolbar.addSubview(copyBtn)
        xOffset += copyBtn.frame.width + 2

        let pinBtn = makeToolbarButton(title: "贴图", tooltip: "钉在屏幕上 (F3)",
                                        at: xOffset, tag: 302, action: #selector(pinImage))
        toolbar.addSubview(pinBtn)
        xOffset += pinBtn.frame.width + 2
        xOffset += 4

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 文字识别 ──
        // 单独成组而不塞进「导出」：它是"从图上取信息"（进剪贴板的是一段文字），
        // 不是"把图送出去"，放在一起会让人以为点了就等于导出图片。
        addGroupLabel("识别", to: toolbar, at: xOffset, width: 76)
        let ocrBtn = makeToolbarButton(title: "OCR", tooltip: "识别截图里的文字（本地离线），结果复制到剪贴板",
                                        at: xOffset, tag: 500, action: #selector(runOCR))
        toolbar.addSubview(ocrBtn)
        xOffset += ocrBtn.frame.width + 2
        xOffset += 4

        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 帮助 ──
        let helpBtn = makeToolbarButton(title: "帮助", tooltip: "查看使用帮助", at: xOffset, tag: 400,
                                         action: #selector(showHelp))
        toolbar.addSubview(helpBtn)

        // 记录工具栏真正需要的宽度 = 布局游标 + 最后一个控件的宽度。
        //
        // 刻意不用「容器里最靠右的子视图」来量：colorButtonContainer 的框架宽度是
        // 固定值（200），与实际色块数量无关，用它会量宽。
        toolbarContentWidth = xOffset + helpBtn.frame.width

        return toolbar
    }

    /// 创建工具栏按钮（统一样式，带文字）
    private func makeToolbarButton(title: String, tooltip: String, at x: CGFloat,
                                    tag: Int, action: Selector) -> NSButton {
        let width = max(CGFloat(title.count) * 14 + 8, 36)
        let btn = NSButton(frame: NSRect(x: x, y: 12, width: width, height: 24))
        btn.title = title
        btn.font = NSFont.systemFont(ofSize: 12)
        btn.bezelStyle = .texturedSquare
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        btn.tag = tag
        btn.wantsLayer = true
        return btn
    }

    /// 在工具栏按钮上方添加分组标签
    private func addGroupLabel(_ text: String, to view: NSView, at x: CGFloat, width: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: x, y: 38, width: width, height: 10)
        view.addSubview(label)
    }

    private func addSeparator(to view: NSView, at xOffset: inout CGFloat, height: CGFloat) {
        let sep = NSBox(frame: NSRect(x: xOffset, y: 6, width: 1, height: height - 12))
        sep.boxType = .separator
        view.addSubview(sep)
        xOffset += 8
    }

    private func rebuildColorButtons() {
        colorButtons.forEach { $0.removeFromSuperview() }
        colorButtons.removeAll()

        let palette = ColorPalette.allPalettes[paletteIndex]
        for (i, color) in palette.colors.enumerated() {
            let btn = NSButton(frame: NSRect(x: CGFloat(i) * 30, y: 12, width: 24, height: 24))
            btn.bezelStyle = .circular
            btn.title = ""
            btn.wantsLayer = true
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.cornerRadius = 12
            btn.layer?.borderWidth = 2
            btn.layer?.borderColor = NSColor.clear.cgColor
            btn.toolTip = palette.name + " - 颜色 \(i + 1)"
            btn.target = self
            btn.action = #selector(colorButtonClicked(_:))
            btn.tag = i
            colorButtonContainer.addSubview(btn)
            colorButtons.append(btn)
        }

        if let first = palette.colors.first {
            annotationView.currentColor = first
            colorButtons.first?.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    private func updateToolButtonStates(selectedIndex: Int) {
        for (i, btn) in toolButtons.enumerated() {
            if i == selectedIndex {
                btn.state = .on
                btn.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            } else {
                btn.state = .off
                btn.layer?.backgroundColor = nil
            }
        }
    }

    // MARK: - Actions

    @objc private func lineWidthChanged(_ sender: NSSlider) {
        let value = CGFloat(sender.doubleValue)
        annotationView.currentLineWidth = value
        lineWidthLabel.stringValue = "\(Int(value))px"
    }

    /// 工具栏上的绘图工具。
    ///
    /// **单一来源**：按钮顺序即 `tag`，`toolButtonClicked` 也从这里取工具。
    /// 此前「标题数组」和「tag → 工具映射数组」是两份独立列表，加一个工具要改两处，
    /// 顺序一旦不同步就会点 A 出 B（且不会有任何编译错误）。
    private static let toolbarTools: [(title: String, tip: String, tool: DrawingTool)] = [
        ("箭头", "绘制箭头标注", .arrow),
        ("矩形", "拖拽绘制矩形框", .rectangle),
        ("圆角", "拖拽绘制圆角矩形", .roundedRectangle),
        ("圆形", "拖拽绘制正圆", .circle),
        ("椭圆", "拖拽绘制椭圆", .ellipse),
        ("聚光", "聚光灯高亮区域", .spotlight),
        ("序号", "单击放置序号标注（编号自动递增）", .step),
        ("文字", "单击放置文字并直接输入（双击已有文字可再次编辑）", .text),
        ("马赛克", "拖拽框选一块区域打马赛克（隐私打码）", .mosaic),
        ("模糊", "拖拽框选一块区域做高斯模糊（隐私打码）", .blur),
        ("橡皮", "拖拽抹掉经过的标注对象（整笔合并为一步撤销）", .eraser),
        ("取色", "从截图上取色：移到目标处单击，HEX 自动进剪贴板", .picker),
    ]

    @objc private func toolButtonClicked(_ sender: NSButton) {
        selectTool(atIndex: sender.tag)
    }

    @objc private func stampSelected(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        if index >= 0 && index < defaultStamps.count {
            let (stampType, _) = defaultStamps[index]
            annotationView.currentTool = .stamp(stampType)
            updateToolButtonStates(selectedIndex: -1)
        }
    }

    @objc private func arrowStyleSelected(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0 && index < ArrowStyle.allPresets.count else { return }
        annotationView.currentArrowStyle = ArrowStyle.allPresets[index]
    }

    @objc private func lineStyleSelected(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        let styles = LineStyle.allCases
        guard index >= 0 && index < styles.count else { return }
        annotationView.currentLineStyle = styles[index]
    }

    @objc private func colorButtonClicked(_ sender: NSButton) {
        let palette = ColorPalette.allPalettes[paletteIndex]
        if sender.tag >= 0 && sender.tag < palette.colors.count {
            annotationView.currentColor = palette.colors[sender.tag]
            for btn in colorButtons {
                btn.layer?.borderColor = NSColor.clear.cgColor
            }
            sender.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    @objc private func cyclePalette() {
        paletteIndex = (paletteIndex + 1) % ColorPalette.allPalettes.count
        rebuildColorButtons()
    }

    @objc private func undoAction() {
        annotationView.performUndo()
    }

    @objc private func redoAction() {
        annotationView.performRedo()
    }

    @objc private func deleteSelectedAction() {
        annotationView.deleteSelectedObject()
    }

    // MARK: - 由 AnnotationView 的键盘处理调用

    /// Enter：复制到剪贴板并关闭标注窗口（Snipaste 的一步到位行为）。
    func copyAndClose() {
        copyImage()
        close()
    }

    /// 把当前画布钉在屏幕上，并关闭标注窗口。
    ///
    /// 关窗的理由和 Enter 一样：贴图是「留在屏幕上继续看」的产物，
    /// 标注窗口再开着就重复占地方了。
    @objc func pinImage() {
        PinManager.shared.pin(annotationView.compositeImage())
        close()
    }

    /// 识别截图里的文字（本地离线），结果复制到剪贴板并在画布上框出位置。
    ///
    /// 之所以要把结果框出来：OCR 如果只往剪贴板里塞文字，用户没法判断是"没识别到"
    /// 还是"识别错了"——只能粘贴到别处再对比。框出来就能一眼看出它读到了哪几块。
    ///
    /// 识别用的是**原始截图**，与已经画上去的标注无关（涂掉的文字照样能认出来）。
    @objc private func runOCR() {
        guard let image = annotationView.baseCGImage else {
            flashHUD("没有可识别的图像")
            return
        }
        flashHUD("正在识别文字…")

        let canvasSize = annotationView.baseImage.size
        TextRecognizer.recognize(in: image, canvasSize: canvasSize) { [weak self] items in
            guard let self = self else { return }
            guard !items.isEmpty else {
                self.annotationView.showOCRHighlights([])
                self.flashHUD("未识别到文字")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(TextRecognizer.joinedText(items), forType: .string)
            self.annotationView.showOCRHighlights(items.map(\.box))
            self.flashHUD("已识别 \(items.count) 段文字　已复制")
        }
    }

    /// Tab / ⇧Tab：按工具栏顺序循环切换绘图工具。
    ///
    /// 放在窗口而不是画布上，是因为切换工具还要同步工具栏按钮的选中态 ——
    /// 而按钮归窗口管。画布只管 `currentTool` 这一个值。
    func cycleTool(reverse: Bool) {
        let current = Self.toolbarTools.firstIndex { $0.tool == annotationView.currentTool }
        // 环绕算术走 CyclicIndex.step（纯函数，已离屏测试过边界）
        selectTool(atIndex: CyclicIndex.step(current,
                                             count: Self.toolbarTools.count,
                                             reverse: reverse))
    }

    /// 按工具栏下标选中工具（数字键直选、Tab 循环、按钮点击都走这里）。
    func selectTool(atIndex index: Int) {
        guard index >= 0 && index < Self.toolbarTools.count else { return }
        annotationView.currentTool = Self.toolbarTools[index].tool
        updateToolButtonStates(selectedIndex: index)
        Preferences.shared.lastToolTag = index
    }

    @objc private func watermarkToggled(_ sender: NSButton) {
        annotationView.watermarkConfig.enabled = (sender.state == .on)
    }

    @objc private func watermarkTextChanged(_ sender: NSTextField) {
        annotationView.watermarkConfig.text = sender.stringValue
    }

    @objc func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "screenshot.png"

        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let self = self else { return }

            let image = self.annotationView.compositeImage()
            guard let data = self.pngData(from: image) else { return }
            do {
                try data.write(to: url)
                self.flashHUD("已保存")
            } catch {
                // 以前是 try? 静默吞掉 —— 磁盘满 / 无权限时用户完全不知道没存上
                self.presentWriteFailure(error, url: url)
            }
        }
    }

    @objc func copyImage() {
        let image = annotationView.compositeImage()
        let pb = NSPasteboard.general
        pb.clearContents()

        // 同时写入「图片内容」与「图片文件」：
        //   - 图片内容 → 可直接粘贴到聊天窗口 / 文档
        //   - 图片文件 → 可在访达里直接 ⌘V 存成 .png
        var items: [NSPasteboardWriting] = [image]
        if let url = writeTemporaryPNG(image) {
            items.append(url as NSURL)
        }
        pb.writeObjects(items)
        flashHUD("已复制")
    }

    // MARK: - 视觉反馈

    private var hudLabel: NSTextField?

    /// 在画布中央短暂显示一条提示。
    ///
    /// 快捷键必须有反馈：⌘C 之后界面上什么都不变的话，用户不确定到底生效没有，
    /// 会重复按很多次。Enter 虽然会关窗口（本身就是反馈），但用它统一处理也无害。
    private func flashHUD(_ text: String) {
        hudLabel?.removeFromSuperview()

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        label.layer?.cornerRadius = 6
        label.sizeToFit()
        label.frame.size.width += 28
        label.frame.size.height += 14
        label.frame.origin = NSPoint(
            x: annotationView.frame.midX - label.frame.width / 2,
            y: annotationView.frame.midY - label.frame.height / 2
        )
        label.alphaValue = 0
        contentView?.addSubview(label)
        hudLabel = label

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            label.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    label.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    label.removeFromSuperview()
                    if self?.hudLabel === label { self?.hudLabel = nil }
                }
            }
        }
    }

    private func presentWriteFailure(_ error: Error, url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "保存失败"
        alert.informativeText = "无法写入 \(url.path)\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 导出辅助

    /// 把 NSImage 编码为 PNG 数据。
    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 写入剪贴板用的临时 PNG，返回其 URL。
    ///
    /// 失败时返回 nil —— 此时调用方仍会写入图片内容，复制功能不受影响。
    /// 文件名带毫秒时间戳，避免连续复制时互相覆盖（文件引用会失效）。
    private func writeTemporaryPNG(_ image: NSImage) -> URL? {
        guard let data = pngData(from: image) else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = "AISnap-\(AnnotationWindow.timestampFormatter.string(from: Date())).png"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AISnap"
        alert.informativeText = "macOS 截图标注工具\n\n支持箭头、矩形、圆形、椭圆、聚光灯、表情贴纸、水印等标注功能。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "AISnap 使用帮助"
        alert.informativeText = """
        【绘图工具】
        - 箭头：在画布上拖拽绘制箭头标注
        - 矩形：拖拽绘制矩形边框
        - 圆角：拖拽绘制圆角矩形（圆角随线宽放大，线宽越大圆角越明显）
        - 圆形：拖拽绘制正圆（取宽高较大值为直径）
        - 椭圆：拖拽绘制椭圆（宽高独立）
        - 聚光：拖拽框选高亮区域，其余区域变暗
        - 序号：单击放置带数字的圆形标记，编号自动递增（1、2、3…）
        - 文字：单击放置后直接打字，回车确认、Esc 取消（见下）
        - 马赛克：拖拽框选一块区域，替换为像素化色块
        - 模糊：拖拽框选一块区域，替换为高斯模糊
        - 橡皮：拖拽抹掉经过的标注对象（可撤销，整笔算一步）
        - 取色：移到目标处单击，颜色成为当前颜色，HEX 自动复制到剪贴板

        【取色器】
        - 移动鼠标即显示 11×11 放大镜与色值，长按拖拽可以边移边比色
        - 取到的是**原始截图**的颜色，不包含你已经画上去的标注
          （否则"这个位置是什么颜色"会随你画过什么而变）
        - 松手时把当前颜色切换成取到的颜色，并复制 #RRGGBB 到剪贴板
        - 取色后仍停在取色工具，方便连续比几个色；按数字键或 Tab 即可换回绘图工具

        【隐私打码】
        - 马赛克与模糊都直接读原始截图的像素，与画布上的其它标注无关，
          因此"先打码、再画箭头"和"先画箭头、再打码"结果一样
        - 选中后按 Option 拖拽可以旋转，理论上模糊区会略微错位，
          打码区域仍完整覆盖，不会漏出原文
        - 打码强度固定（马赛克 12 点、模糊半径 12 点），暂未提供调节入口

        【文字标注】
        - 单击画布即可输入，放完就能打字，不用再点第二次
        - 回车确认，Esc 取消；点到别处也会自动确认
        - 双击已有文字可以重新编辑（改错字不用删了重画）
        - 字号默认 20；选中后用缩放手柄拖拽即可调大小（缩放作用在字号上）
        - 颜色跟随工具栏当前颜色

        【箭头样式】
        选中"箭头"工具后，用工具栏的「箭头样式」下拉切换：
        实心 / 开放 / 虚线 / 菱形 / 圆端 / 点菱 / 双向 / 双开放。
        其中「双向」「双开放」两端都有箭头。

        【线型】
        矩形与椭圆（含正圆）支持实线 / 虚线 / 点线，用工具栏的「线型」下拉切换，
        选取后新建的形状即采用该线型。箭头的线型请用上面的「箭头样式」——
        它的虚线、点菱等预设已包含线型。
        注：虚线形状的空隙不影响点选 —— 命中检测始终按实线判定，
        因此点到空隙上同样能选中该形状。

        【端点捕捉】
        鼠标悬停在已有对象的中心、边角、象限点附近时
        会显示青色十字捕捉指示器，便于精确对齐（如同心圆）

        【贴纸】
        从下拉菜单选择表情，然后在画布上单击放置

        【编辑操作】
        - 点击对象可选中，拖拽可移动
        - 选中后右上角出现红色 X 可删除
        - Delete 键也可删除选中对象
        - Cmd+Z 撤销，Cmd+Shift+Z 重做

        【变换操作】
        - Option + 拖拽 = 旋转选中对象
        - Shift + 拖拽 = 缩放选中对象

        【颜色】
        点击颜色圆点切换颜色，"换色"按钮切换调色板

        【水印】
        勾选"启用"并输入文本，导出时自动叠加平铺水印

        【键盘】
        标注阶段可以全程不碰鼠标：
        - Enter        复制到剪贴板并关闭窗口（最常用，一步到位）
        - F3           把这张图钉在屏幕上，然后关闭窗口
        - ⌘C           复制到剪贴板（不关窗口）
        - ⌘S           保存为 PNG 文件
        - Tab / ⇧Tab   循环切换绘图工具
        - 1 ~ 7        直接选中第 N 个绘图工具（按工具栏从左到右的顺序）
        - Esc          取消选中，回到绘制模式
        - Delete       删除选中的对象（连同挂在它上面的箭头）
        - ⌘Z / ⇧⌘Z     撤销 / 重做
        - ⌘D           显示 / 隐藏右侧的 Layer B 调试面板（开发用，默认隐藏）

        【贴图（Pin）】
        点工具栏「贴图」或按 F3，图就钉在屏幕上，可以一边看着一边做别的事。
        - 拖动：直接拖
        - 缩放：滚轮，或右键菜单的放大/缩小/实际大小
        - 双击：关闭这张贴图
        - 右键：复制 / 保存 / 不透明度 / 关闭这张 / 关闭全部
        - Esc：关闭当前贴图（点过它之后生效）
        贴图会跟随你切换桌面和全屏应用，并且不会被后续截图拍进去。
        
        【导出】
        - 保存：导出为 PNG 文件
        - 复制：复制到系统剪贴板（同时写入图片内容和图片文件，
          因此既可直接粘贴到聊天窗口，也能在访达里 ⌘V 存成 .png）
        - 贴图：把当前画面钉在屏幕上（F3），可拖动、滚轮缩放、双击关闭

        【文字识别（OCR）】
        - 点「OCR」识别截图里的文字，结果按阅读顺序拼好复制到剪贴板
        - 识别到的地方会在画布上框出来，按 Esc 清除
        - 完全本地离线（系统自带 Vision），不需要联网、不需要账号
        - 识别的是原始截图，与已经画上去的标注无关
        - 大图识别需要几百毫秒，期间界面不会卡住（在后台线程跑）

        【截图历史】
        - 每次截图都会在原图留一份（含没有保存的），最多最近 \(CaptureHistory.maximumEntries) 张
        - 状态栏菜单 →「截图历史…」可浏览、重新编辑、复制、删除或清空
        - 截图常含敏感内容：不需要就清空，或到「偏好设置 → 截图历史」里关掉
          （关掉后连写盘都不发生）

        【设置会自动记住】
        线宽、颜色、线型、箭头样式、调色板、水印与上次使用的工具都会保存下来，
        下次启动沿用，不需要每次重新调。
        要恢复到出厂值：点状态栏图标 →「偏好设置…」。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
