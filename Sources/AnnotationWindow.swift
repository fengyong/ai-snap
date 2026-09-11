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

    init(image: NSImage) {
        let imageSize = image.size
        let toolbarHeight: CGFloat = 48

        // 右侧 debug 面板 = 原图 50% 大小
        let debugScale: CGFloat = 0.5
        let debugPadding: CGFloat = 8

        // 计算自适应缩放：确保窗口不超过屏幕可见区域的 90%
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screenFrame.width * 0.9
        let maxH = screenFrame.height * 0.9 - toolbarHeight

        let naturalTotalW = imageSize.width * (1 + debugScale) + debugPadding
        let naturalTotalH = imageSize.height

        let fitScale = min(1.0, min(maxW / naturalTotalW, maxH / naturalTotalH))

        let canvasW = imageSize.width * fitScale
        let canvasH = imageSize.height * fitScale
        let debugWidth = canvasW * debugScale
        let debugHeight = canvasH * debugScale

        // 画布 + 调试面板所需的宽度
        let contentWidth = canvasW + debugPadding + debugWidth
        let contentHeight = max(canvasH, debugHeight) + toolbarHeight

        // 先用画布侧的宽度初始化。窗口的最终宽度还要看工具栏需要多宽，而工具栏
        // 需要 self 才能创建，所以只能先建窗口、建完工具栏再调宽度（见下方）。
        let initialWidth = max(contentWidth, 400)
        let initialOrigin = NSPoint(
            x: screenFrame.midX - initialWidth / 2,
            y: screenFrame.midY - contentHeight / 2
        )

        super.init(
            contentRect: NSRect(origin: initialOrigin,
                                size: NSSize(width: initialWidth, height: contentHeight)),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "AISnap - 标注"
        self.isReleasedWhenClosed = false

        // 设置应用菜单栏
        setupMainMenu()

        let container = NSView(frame: NSRect(origin: .zero,
                                             size: NSSize(width: initialWidth,
                                                          height: contentHeight)))

        // 标注画布
        annotationView = AnnotationView(image: image)
        annotationView.frame = NSRect(x: 0, y: toolbarHeight,
                                      width: canvasW, height: canvasH)
        if fitScale < 1.0 {
            annotationView.setBoundsSize(imageSize)
        }
        container.addSubview(annotationView)

        // Layer B 调试面板
        let debugImageView = NSImageView(frame: NSRect(
            x: canvasW + debugPadding,
            y: toolbarHeight + (canvasH - debugHeight),
            width: debugWidth,
            height: debugHeight
        ))
        debugImageView.imageScaling = .scaleProportionallyDown
        debugImageView.wantsLayer = true
        debugImageView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        debugImageView.layer?.borderColor = NSColor.separatorColor.cgColor
        debugImageView.layer?.borderWidth = 1
        debugImageView.layer?.cornerRadius = 4
        container.addSubview(debugImageView)

        annotationView.debugImageView = debugImageView

        let debugLabel = NSTextField(labelWithString: "Layer B (Debug)")
        debugLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        debugLabel.textColor = .secondaryLabelColor
        debugLabel.frame = NSRect(
            x: canvasW + debugPadding,
            y: toolbarHeight + canvasH - debugHeight - 16,
            width: debugWidth,
            height: 14
        )
        debugLabel.alignment = .center
        container.addSubview(debugLabel)

        // 底部工具栏（先按初始宽度建出来，建完就能量出它真正需要多宽）
        let toolbar = createToolbar(width: initialWidth, height: toolbarHeight)
        container.addSubview(toolbar)

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

    /// 按工具栏的实际需求调整窗口宽度，并同步容器与工具栏的框架。
    private func resizeWindow(to size: NSSize, container: NSView,
                              toolbar: NSView, screen: NSRect) {
        setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)
        toolbar.frame = NSRect(x: 0, y: 0, width: size.width, height: toolbar.frame.height)
        toolbarTopSeparator?.frame = NSRect(x: 0, y: toolbar.frame.height - 1,
                                            width: size.width, height: 1)
        setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2,
                               y: screen.midY - frame.height / 2))
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
        addGroupLabel("绘图工具", to: toolbar, at: xOffset, width: 268)
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
    ]

    @objc private func toolButtonClicked(_ sender: NSButton) {
        let tools = Self.toolbarTools
        guard sender.tag >= 0 && sender.tag < tools.count else { return }
        annotationView.currentTool = tools[sender.tag].tool
        updateToolButtonStates(selectedIndex: sender.tag)
        Preferences.shared.lastToolTag = sender.tag
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
        // 模拟 Delete 键
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: windowNumber,
                                     context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: 51)
        if let event = event {
            annotationView.keyDown(with: event)
        }
    }

    @objc private func watermarkToggled(_ sender: NSButton) {
        annotationView.watermarkConfig.enabled = (sender.state == .on)
    }

    @objc private func watermarkTextChanged(_ sender: NSTextField) {
        annotationView.watermarkConfig.text = sender.stringValue
    }

    @objc private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "screenshot.png"

        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let self = self else { return }

            let image = self.annotationView.compositeImage()
            if let data = self.pngData(from: image) {
                try? data.write(to: url)
            }
        }
    }

    @objc private func copyImage() {
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
        - 圆角：拖拽绘制圆角矩形（默认圆角半径 12）
        - 圆形：拖拽绘制正圆（取宽高较大值为直径）
        - 圆形：拖拽绘制正圆（取宽高较大值为直径）
        - 椭圆：拖拽绘制椭圆（宽高独立）
        - 聚光：拖拽框选高亮区域，其余区域变暗
        - 序号：单击放置带数字的圆形标记，编号自动递增（1、2、3…）

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

        【导出】
        - 保存：导出为 PNG 文件
        - 复制：复制到系统剪贴板（同时写入图片内容和图片文件，
          因此既可直接粘贴到聊天窗口，也能在访达里 ⌘V 存成 .png）

        【设置会自动记住】
        线宽、颜色、线型、箭头样式、调色板、水印与上次使用的工具都会保存下来，
        下次启动沿用，不需要每次重新调。
        要恢复到出厂值：点状态栏图标 →「恢复默认设置」。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
