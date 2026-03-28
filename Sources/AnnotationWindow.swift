import Cocoa

/// 标注窗口 — 包含工具栏和标注画布，右侧附带 Layer B 调试面板
class AnnotationWindow: NSWindow {
    private var annotationView: AnnotationView!
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var colorButtonContainer: NSView!
    private var paletteIndex: Int = 0
    private var watermarkField: NSTextField!
    private var lineWidthLabel: NSTextField!

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

        let totalWidth = canvasW + debugPadding + debugWidth
        let windowSize = NSSize(width: max(totalWidth, 780),
                                height: max(canvasH, debugHeight) + toolbarHeight)

        let origin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2
        )

        super.init(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "AISnap - 标注"
        self.isReleasedWhenClosed = false

        // 设置应用菜单栏
        setupMainMenu()

        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))

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

        // 底部工具栏
        let toolbar = createToolbar(width: windowSize.width, height: toolbarHeight)
        container.addSubview(toolbar)

        self.contentView = container
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

        var xOffset: CGFloat = 8

        // ── 绘图工具（带文字标签）──
        addGroupLabel("绘图工具", to: toolbar, at: xOffset, width: 190)
        let tools: [(String, String)] = [
            ("箭头", "绘制箭头标注"),
            ("矩形", "绘制矩形框"),
            ("圆形", "拖拽绘制正圆"),
            ("椭圆", "拖拽绘制椭圆"),
            ("聚光", "聚光灯高亮区域"),
        ]
        for (i, (title, tip)) in tools.enumerated() {
            let btn = makeToolbarButton(title: title, tooltip: tip, at: xOffset, tag: i,
                                        action: #selector(toolButtonClicked(_:)))
            toolbar.addSubview(btn)
            toolButtons.append(btn)
            xOffset += btn.frame.width + 2
        }
        updateToolButtonStates(selectedIndex: 0)
        xOffset += 4

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
        wmToggle.state = .off
        wmToggle.font = NSFont.systemFont(ofSize: 11)
        wmToggle.toolTip = "导出图片时叠加水印"
        toolbar.addSubview(wmToggle)
        xOffset += 50

        watermarkField = NSTextField(frame: NSRect(x: xOffset, y: 14, width: 72, height: 20))
        watermarkField.stringValue = "AISnap"
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

    @objc private func toolButtonClicked(_ sender: NSButton) {
        let tools: [DrawingTool] = [.arrow, .rectangle, .circle, .ellipse, .spotlight]
        if sender.tag >= 0 && sender.tag < tools.count {
            annotationView.currentTool = tools[sender.tag]
            updateToolButtonStates(selectedIndex: sender.tag)
        }
    }

    @objc private func stampSelected(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        if index >= 0 && index < defaultStamps.count {
            let (stampType, _) = defaultStamps[index]
            annotationView.currentTool = .stamp(stampType)
            updateToolButtonStates(selectedIndex: -1)
        }
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
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }

    @objc private func copyImage() {
        let image = annotationView.compositeImage()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

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
        - 圆形：拖拽绘制正圆（取宽高较大值为直径）
        - 椭圆：拖拽绘制椭圆（宽高独立）
        - 聚光：拖拽框选高亮区域，其余区域变暗

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
        - 复制：复制到系统剪贴板
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
