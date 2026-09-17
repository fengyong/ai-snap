import Cocoa

/// 标注窗口 — 包含工具栏和标注画布。
///
/// 修复要点（对应 CODE_REVIEW.md）：
///  * P0-2：窗口最小宽度按**工具栏实际所需宽度**计算，窄截图不再把「保存/复制/帮助」挤出窗口；
///          同时补上 Cmd+S / Cmd+C 菜单项，导出路径永远可达。
///  * P1-5：Layer B 调试面板**默认关闭**（它是拖拽卡顿的主因），通过「视图」菜单按需打开。
///  * P4-19：切换调色板后重建工具栏，色板不会压住后面的控件。
///  * P2-1：水印文本实时同步，不必按回车。
///  * P2-3/P4-20：有关闭确认，不会静默丢弃标注。
///  * P2-2：窗口关闭后恢复 `.accessory`（纯菜单栏应用）。
class AnnotationWindow: NSWindow, NSWindowDelegate, NSTextFieldDelegate {
    private var annotationView: AnnotationView!
    private var container: NSView!
    private var toolbarView: NSView?
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var colorButtonContainer: NSView!
    private var paletteIndex: Int = 0
    private var watermarkField: NSTextField!
    private var watermarkToggle: NSButton!
    private var lineWidthLabel: NSTextField!
    private var lineWidthSlider: NSSlider!
    private var debugImageView: NSImageView?
    private var debugLabel: NSTextField?
    private var debugToggleItem: NSMenuItem?

    /// Layer B 调试面板默认关闭：它每次拖拽都要重绘一整张画布，
    /// 实测让单次拖拽事件从 ~0.2ms 涨到 ~25ms（约 145 倍），是拖拽卡顿的主因。
    private(set) var showsDebugPanel = false

    private let toolbarHeight: CGFloat = 48
    private let canvasSize: NSSize
    private let fitScale: CGFloat
    private var toolbarRequiredWidth: CGFloat = 780

    // MARK: - Init

    init(image: NSImage, screen: NSScreen? = nil, pixelSize: CGSize? = nil) {
        let imageSize = image.size
        let host = screen ?? NSScreen.screens.first   // 兜底用主显示器，不用 NSScreen.main
        let screenFrame = host?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let maxW = screenFrame.width * 0.9
        let maxH = screenFrame.height * 0.9 - toolbarHeight
        let fitScale = min(1.0, min(maxW / max(imageSize.width, 1), maxH / max(imageSize.height, 1)))

        self.fitScale = fitScale
        self.canvasSize = NSSize(width: imageSize.width * fitScale,
                                 height: imageSize.height * fitScale)

        // 先用一个保守尺寸初始化，真实尺寸在 layoutContent() 里按工具栏所需宽度重算
        let initialSize = NSSize(width: max(canvasSize.width, 780),
                                 height: canvasSize.height + toolbarHeight)
        let origin = NSPoint(x: screenFrame.midX - initialSize.width / 2,
                             y: screenFrame.midY - initialSize.height / 2)

        super.init(contentRect: NSRect(origin: origin, size: initialSize),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered,
                   defer: false)

        self.title = "AISnap - 标注"
        self.isReleasedWhenClosed = false
        self.delegate = self

        setupMainMenu()

        container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        self.contentView = container

        annotationView = AnnotationView(image: image, pixelSize: pixelSize)
        annotationView.frame = NSRect(x: 0, y: toolbarHeight,
                                      width: canvasSize.width, height: canvasSize.height)
        if fitScale < 1.0 {
            annotationView.setBoundsSize(imageSize)
        }
        container.addSubview(annotationView)

        // 选中对象变化时把工具栏同步成该对象的样式
        annotationView.onSelectionChanged = { [weak self] in
            self?.syncToolbarToSelection()
        }

        rebuildToolbar()
        layoutContent()
    }

    /// 把工具栏同步成"当前选中对象"的样式：调色板高亮 + 线宽显示。
    /// 这样选中一个已有箭头后能直接看出它的颜色/粗细，点色点即可改它。
    private func syncToolbarToSelection() {
        if let color = annotationView.selectedObjectColor {
            let palette = ColorPalette.allPalettes[paletteIndex]
            for (i, btn) in colorButtons.enumerated() {
                let isSame = i < palette.colors.count && Self.colorsEqual(palette.colors[i], color)
                btn.layer?.borderColor = isSame
                    ? NSColor.controlAccentColor.cgColor
                    : NSColor.clear.cgColor
            }
        }
        if let width = annotationView.selectedObjectLineWidth {
            lineWidthSlider?.doubleValue = Double(width)
            lineWidthLabel?.stringValue = "\(Int(width))px"
        }
    }

    private static func colorsEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.deviceRGB), let y = b.usingColorSpace(.deviceRGB) else { return a == b }
        return abs(x.redComponent - y.redComponent) < 0.002
            && abs(x.greenComponent - y.greenComponent) < 0.002
            && abs(x.blueComponent - y.blueComponent) < 0.002
    }

    // MARK: - Layout

    /// 按"工具栏实际所需宽度"决定窗口宽度，避免导出按钮被挤出窗口（P0-2）
    private func layoutContent() {
        let padding: CGFloat = 8
        let debugWidth = showsDebugPanel ? canvasSize.width * 0.5 : 0
        let needed = canvasSize.width + (showsDebugPanel ? debugWidth + padding : 0)
        let width = max(needed, toolbarRequiredWidth + padding * 2)
        let height = canvasSize.height + toolbarHeight

        let newSize = NSSize(width: width, height: height)
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 {
            let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
            setContentSize(newSize)
            setFrameTopLeftPoint(topLeft)
        }
        container.frame = NSRect(origin: .zero, size: newSize)

        annotationView.frame = NSRect(x: 0, y: toolbarHeight,
                                      width: canvasSize.width, height: canvasSize.height)

        if showsDebugPanel {
            let debugX = canvasSize.width + padding
            let debugH = canvasSize.height * 0.5
            let imageView = debugImageView ?? NSImageView()
            imageView.frame = NSRect(x: debugX,
                                     y: toolbarHeight + (canvasSize.height - debugH),
                                     width: debugWidth, height: debugH)
            imageView.imageScaling = .scaleProportionallyDown
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            imageView.layer?.borderColor = NSColor.separatorColor.cgColor
            imageView.layer?.borderWidth = 1
            imageView.layer?.cornerRadius = 4
            if imageView.superview == nil { container.addSubview(imageView) }
            debugImageView = imageView
            annotationView.debugImageView = imageView

            let label = debugLabel ?? NSTextField(labelWithString: "Layer B (Debug)")
            label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.frame = NSRect(x: debugX,
                                 y: toolbarHeight + canvasSize.height - debugH - 16,
                                 width: debugWidth, height: 14)
            if label.superview == nil { container.addSubview(label) }
            debugLabel = label
        } else {
            debugImageView?.removeFromSuperview()
            debugImageView = nil
            debugLabel?.removeFromSuperview()
            debugLabel = nil
            annotationView.debugImageView = nil      // 断开后 refreshDebugView() 直接返回，拖拽不再重绘
        }

        toolbarView?.frame = NSRect(x: 0, y: 0, width: width, height: toolbarHeight)
    }

    // MARK: - Main Menu Bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // ── AISnap ──
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 AISnap", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "退出 AISnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in appMenu.items { item.target = self }
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ── 文件：与布局无关的导出入口（P0-2 的兜底）──
        let fileMenu = NSMenu(title: "文件")
        let saveItem = NSMenuItem(title: "保存为 PNG…", action: #selector(saveImage), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)
        let copyItem = NSMenuItem(title: "复制到剪贴板", action: #selector(copyImage), keyEquivalent: "c")
        copyItem.target = self
        fileMenu.addItem(copyItem)
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // ── 编辑 ──
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

        // ── 视图：Layer B 调试面板开关（默认关）──
        let viewMenu = NSMenu(title: "视图")
        let debugItem = NSMenuItem(title: "显示 Layer B 调试面板",
                                   action: #selector(toggleDebugPanel), keyEquivalent: "d")
        debugItem.keyEquivalentModifierMask = [.command, .shift]
        debugItem.target = self
        debugItem.state = .off
        viewMenu.addItem(debugItem)
        debugToggleItem = debugItem
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // ── 帮助 ──
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

    @objc private func toggleDebugPanel(_ sender: NSMenuItem) {
        showsDebugPanel.toggle()
        sender.state = showsDebugPanel ? .on : .off
        layoutContent()
        if showsDebugPanel { annotationView.refreshDebugView() }
    }

    // MARK: - Toolbar

    private func rebuildToolbar() {
        toolbarView?.removeFromSuperview()
        toolButtons.removeAll()
        colorButtons.removeAll()
        let bar = createToolbar(width: max(canvasSize.width, 780))
        toolbarView = bar
        container.addSubview(bar)
    }

    private func createToolbar(width: CGFloat) -> NSView {
        let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: toolbarHeight))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        var xOffset: CGFloat = 8

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
        let toolList: [DrawingTool] = [.arrow, .rectangle, .circle, .ellipse, .spotlight]
        let selectedToolIndex = toolList.firstIndex { $0 == annotationView.currentTool } ?? 0
        updateToolButtonStates(selectedIndex: selectedToolIndex)
        xOffset += 4

        addSeparator(to: toolbar, at: &xOffset)
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

        addSeparator(to: toolbar, at: &xOffset)
        addGroupLabel("颜色", to: toolbar, at: xOffset, width: 200)
        let paletteBtn = makeToolbarButton(title: "换色", tooltip: "切换调色板", at: xOffset, tag: 200,
                                           action: #selector(cyclePalette))
        toolbar.addSubview(paletteBtn)
        xOffset += paletteBtn.frame.width + 4

        colorButtonContainer = NSView(frame: NSRect(x: xOffset, y: 0, width: 160, height: toolbarHeight))
        toolbar.addSubview(colorButtonContainer)
        rebuildColorButtons()
        xOffset += colorButtonContainer.frame.width + 4

        addSeparator(to: toolbar, at: &xOffset)
        addGroupLabel("线宽", to: toolbar, at: xOffset, width: 100)
        let slider = NSSlider(frame: NSRect(x: xOffset, y: 14, width: 70, height: 20))
        slider.minValue = 1
        slider.maxValue = 30
        slider.doubleValue = Double(annotationView.currentLineWidth)
        slider.target = self
        slider.action = #selector(lineWidthChanged(_:))
        slider.toolTip = "调节线条粗细 (1-30)"
        toolbar.addSubview(slider)
        lineWidthSlider = slider

        let label = NSTextField(labelWithString: "\(Int(annotationView.currentLineWidth))px")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: xOffset + 72, y: 16, width: 32, height: 14)
        toolbar.addSubview(label)
        lineWidthLabel = label
        xOffset += 108

        addSeparator(to: toolbar, at: &xOffset)
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

        addSeparator(to: toolbar, at: &xOffset)
        addGroupLabel("水印", to: toolbar, at: xOffset, width: 140)
        let wmToggle = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(watermarkToggled(_:)))
        wmToggle.frame = NSRect(x: xOffset, y: 14, width: 48, height: 20)
        wmToggle.state = annotationView.watermarkConfig.enabled ? .on : .off
        wmToggle.font = NSFont.systemFont(ofSize: 11)
        wmToggle.toolTip = "导出图片时叠加水印"
        toolbar.addSubview(wmToggle)
        watermarkToggle = wmToggle
        xOffset += 50

        // 水印文本：delegate 实时同步（旧实现只挂 action，用户不按回车就白改了）
        let field = NSTextField(frame: NSRect(x: xOffset, y: 14, width: 72, height: 20))
        field.stringValue = annotationView.watermarkConfig.text
        field.font = NSFont.systemFont(ofSize: 11)
        field.placeholderString = "水印文本"
        field.toolTip = "输入水印文本内容"
        field.delegate = self
        field.target = self
        field.action = #selector(watermarkTextChanged(_:))
        field.cell?.sendsActionOnEndEditing = true
        toolbar.addSubview(field)
        watermarkField = field
        xOffset += 78

        addSeparator(to: toolbar, at: &xOffset)
        addGroupLabel("导出", to: toolbar, at: xOffset, width: 110)
        let saveBtn = makeToolbarButton(title: "保存", tooltip: "保存为 PNG 文件 (Cmd+S)", at: xOffset, tag: 300,
                                        action: #selector(saveImage))
        toolbar.addSubview(saveBtn)
        xOffset += saveBtn.frame.width + 2
        let copyBtn = makeToolbarButton(title: "复制", tooltip: "复制到剪贴板 (Cmd+C)", at: xOffset, tag: 301,
                                        action: #selector(copyImage))
        toolbar.addSubview(copyBtn)
        xOffset += copyBtn.frame.width + 2
        xOffset += 4

        addSeparator(to: toolbar, at: &xOffset)
        let helpBtn = makeToolbarButton(title: "帮助", tooltip: "查看使用帮助", at: xOffset, tag: 400,
                                        action: #selector(showHelp))
        toolbar.addSubview(helpBtn)
        xOffset += helpBtn.frame.width

        // 记录工具栏真正需要的宽度，窗口最小宽度据此决定（P0-2）
        toolbarRequiredWidth = xOffset + 8
        return toolbar
    }

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

    private func addGroupLabel(_ text: String, to view: NSView, at x: CGFloat, width: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: x, y: 38, width: width, height: 10)
        view.addSubview(label)
    }

    private func addSeparator(to view: NSView, at xOffset: inout CGFloat) {
        let sep = NSBox(frame: NSRect(x: xOffset, y: 6, width: 1, height: toolbarHeight - 12))
        sep.boxType = .separator
        view.addSubview(sep)
        xOffset += 8
    }

    private func rebuildColorButtons() {
        colorButtons.forEach { $0.removeFromSuperview() }
        colorButtons.removeAll()
        guard let container = colorButtonContainer else { return }

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
            container.addSubview(btn)
            colorButtons.append(btn)
        }
        // 容器宽度跟随色数，后面的控件位置才不会重叠（P4-19）
        container.frame.size.width = max(CGFloat(palette.colors.count) * 30, 30)

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
        annotationView.currentLineWidth = value           // 影响之后新画的对象
        annotationView.restyleSelection(lineWidth: value) // 有选中对象时同时改它
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
        guard sender.tag >= 0, sender.tag < palette.colors.count else { return }
        let color = palette.colors[sender.tag]

        annotationView.currentColor = color              // 影响之后新画的对象
        annotationView.restyleSelection(color: color)    // 有选中对象时直接换成这个颜色

        for btn in colorButtons {
            btn.layer?.borderColor = NSColor.clear.cgColor
        }
        sender.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    @objc private func cyclePalette() {
        paletteIndex = (paletteIndex + 1) % ColorPalette.allPalettes.count
        // 色数变化会改变后续控件的应有位置：整体重建工具栏，而不是只换色点（P4-19）
        rebuildToolbar()
        layoutContent()
    }

    @objc private func undoAction() { annotationView.performUndo() }
    @objc private func redoAction() { annotationView.performRedo() }

    @objc private func deleteSelectedAction() {
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

    /// 实时同步（不必按回车）
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === watermarkField else { return }
        annotationView.watermarkConfig.text = field.stringValue
    }

    // MARK: - Export

    @objc private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "screenshot.png"

        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            let image = self.annotationView.compositeImage()
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                self.presentError("无法生成 PNG 数据")
                return
            }
            do {
                try png.write(to: url)
            } catch {
                self.presentError("保存失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func copyImage() {
        let image = annotationView.compositeImage()
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.writeObjects([image]) {
            presentError("写入剪贴板失败")
        }
    }

    /// 保存失败不再静默吞掉（旧实现是 `try?`）
    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "操作失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        alert.beginSheetModal(for: self)
    }

    // MARK: - Close / Discard

    /// 是否还有未导出的标注
    var hasUnsavedWork: Bool { annotationView?.hasEdits ?? false }

    /// 供 AppDelegate 在"重新截图会丢弃当前标注"前调用
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedWork else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃当前标注？"
        alert.informativeText = "当前截图上的标注还没有导出，继续操作会丢失它们。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "放弃并继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        // 恢复纯菜单栏应用形态（P2-2）
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Help / About

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AISnap"
        alert.informativeText = "macOS 截图标注工具\n\n支持箭头、矩形、圆形、椭圆、聚光灯、表情贴纸、水印等标注功能。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
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
        - 聚光：拖拽框选高亮区域，其余区域变暗（可叠加多个）

        【端点捕捉与附着】
        鼠标悬停在已有对象的中心、边角、象限点附近时会出现青色十字指示器；
        箭头端点落在形状附近会自动附着，之后形状移动/旋转/缩放时箭头会跟随。

        【贴纸】
        从下拉菜单选择表情，然后在画布上单击放置

        【编辑操作】
        - 点击对象可选中，拖拽可移动
        - 选中后右上角出现红色 X 可删除，Delete 键同样可删除
        - Cmd+Z 撤销，Cmd+Shift+Z 重做

        【变换操作】
        - 选中对象后，Option + 拖拽 = 旋转，Shift + 拖拽 = 缩放

        【颜色与水印】
        - 点击颜色圆点切换颜色，"换色"按钮切换调色板
        - 勾选"启用"并输入文本，导出时自动叠加平铺水印

        【导出】
        - 保存：导出为 PNG 文件（Cmd+S）
        - 复制：复制到系统剪贴板（Cmd+C）

        【调试】
        - 视图 → 显示 Layer B 调试面板（Cmd+Shift+D），默认关闭
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
