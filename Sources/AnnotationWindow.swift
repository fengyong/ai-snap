import Cocoa

/// 标注窗口 — 包含工具栏和标注画布，右侧附带 Layer B 调试面板
class AnnotationWindow: NSWindow {
    private var annotationView: AnnotationView!
    private var toolButtons: [NSButton] = []
    private var arrowStyleButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var colorButtonContainer: NSView!
    private var paletteIndex: Int = 0

    init(image: NSImage) {
        let imageSize = image.size
        let toolbarHeight: CGFloat = 44

        // 右侧 debug 面板 = 原图 50% 大小
        let debugScale: CGFloat = 0.5
        let debugWidth = imageSize.width * debugScale
        let debugHeight = imageSize.height * debugScale
        let debugPadding: CGFloat = 8

        // 窗口宽度 = 原图 + 间距 + debug 面板
        let totalWidth = imageSize.width + debugPadding + debugWidth
        let windowSize = NSSize(width: max(totalWidth, 620),
                                height: max(imageSize.height, debugHeight) + toolbarHeight)

        // 居中显示
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
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

        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))

        // 标注画布（左侧）
        annotationView = AnnotationView(image: image)
        annotationView.frame = NSRect(x: 0, y: toolbarHeight,
                                      width: imageSize.width, height: imageSize.height)
        container.addSubview(annotationView)

        // Layer B 调试面板（右侧，50% 大小）
        let debugImageView = NSImageView(frame: NSRect(
            x: imageSize.width + debugPadding,
            y: toolbarHeight + (imageSize.height - debugHeight),
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

        // 挂载到 annotationView，让它能实时刷新
        annotationView.debugImageView = debugImageView

        // debug 面板标签
        let debugLabel = NSTextField(labelWithString: "Layer B (Debug)")
        debugLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        debugLabel.textColor = .secondaryLabelColor
        debugLabel.frame = NSRect(
            x: imageSize.width + debugPadding,
            y: toolbarHeight + imageSize.height - debugHeight - 16,
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

    // MARK: - Toolbar

    private func createToolbar(width: CGFloat, height: CGFloat) -> NSView {
        let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // 分隔线
        let separator = NSBox(frame: NSRect(x: 0, y: height - 1, width: width, height: 1))
        separator.boxType = .separator
        toolbar.addSubview(separator)

        var xOffset: CGFloat = 8

        // ── 工具选择 ──
        let tools: [(String, String)] = [
            ("↗", "箭头"), ("▭", "矩形"), ("○", "圆形"),
        ]
        for (i, (title, tip)) in tools.enumerated() {
            let btn = NSButton(frame: NSRect(x: xOffset, y: 8, width: 32, height: 28))
            btn.title = title
            btn.bezelStyle = .texturedSquare
            btn.toolTip = tip
            btn.target = self
            btn.action = #selector(toolButtonClicked(_:))
            btn.tag = i
            btn.wantsLayer = true
            toolbar.addSubview(btn)
            toolButtons.append(btn)
            xOffset += 34
        }
        updateToolButtonStates(selectedIndex: 0)

        xOffset += 6

        // ── 分隔符 ──
        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 箭头样式 ──
        for (i, name) in ArrowStyle.presetNames.enumerated() {
            let btn = NSButton(frame: NSRect(x: xOffset, y: 8, width: 32, height: 28))
            btn.title = String(name.prefix(2))
            btn.font = NSFont.systemFont(ofSize: 10)
            btn.bezelStyle = .texturedSquare
            btn.toolTip = "箭头样式: \(name)"
            btn.target = self
            btn.action = #selector(arrowStyleButtonClicked(_:))
            btn.tag = i
            btn.wantsLayer = true
            toolbar.addSubview(btn)
            arrowStyleButtons.append(btn)
            xOffset += 34
        }
        updateArrowStyleStates(selectedIndex: 0)

        xOffset += 6

        // ── 分隔符 ──
        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 调色板切换按钮 ──
        let paletteBtn = NSButton(frame: NSRect(x: xOffset, y: 8, width: 28, height: 28))
        paletteBtn.title = "◆"
        paletteBtn.bezelStyle = .texturedSquare
        paletteBtn.toolTip = "切换调色板"
        paletteBtn.target = self
        paletteBtn.action = #selector(cyclePalette)
        toolbar.addSubview(paletteBtn)
        xOffset += 32

        // ── 颜色按钮容器 ──
        colorButtonContainer = NSView(frame: NSRect(x: xOffset, y: 0, width: 200, height: height))
        toolbar.addSubview(colorButtonContainer)
        rebuildColorButtons()
        xOffset += CGFloat(ColorPalette.allPalettes[paletteIndex].colors.count) * 32 + 8

        // ── 分隔符 ──
        addSeparator(to: toolbar, at: &xOffset, height: height)

        // ── 保存按钮 ──
        let saveBtn = NSButton(frame: NSRect(x: xOffset, y: 8, width: 50, height: 28))
        saveBtn.title = "保存"
        saveBtn.bezelStyle = .rounded
        saveBtn.target = self
        saveBtn.action = #selector(saveImage)
        toolbar.addSubview(saveBtn)
        xOffset += 56

        // ── 复制按钮 ──
        let copyBtn = NSButton(frame: NSRect(x: xOffset, y: 8, width: 50, height: 28))
        copyBtn.title = "复制"
        copyBtn.bezelStyle = .rounded
        copyBtn.target = self
        copyBtn.action = #selector(copyImage)
        toolbar.addSubview(copyBtn)

        return toolbar
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
            let btn = NSButton(frame: NSRect(x: CGFloat(i) * 32, y: 8, width: 26, height: 26))
            btn.bezelStyle = .circular
            btn.title = ""
            btn.wantsLayer = true
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.cornerRadius = 13
            btn.layer?.borderWidth = 2
            btn.layer?.borderColor = NSColor.clear.cgColor
            btn.target = self
            btn.action = #selector(colorButtonClicked(_:))
            btn.tag = i
            colorButtonContainer.addSubview(btn)
            colorButtons.append(btn)
        }

        // 默认选中第一个颜色
        if let first = palette.colors.first {
            annotationView.currentColor = first
            colorButtons.first?.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    private func updateToolButtonStates(selectedIndex: Int) {
        for (i, btn) in toolButtons.enumerated() {
            if i == selectedIndex {
                btn.state = .on
                btn.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            } else {
                btn.state = .off
                btn.layer?.backgroundColor = nil
            }
        }
    }

    private func updateArrowStyleStates(selectedIndex: Int) {
        for (i, btn) in arrowStyleButtons.enumerated() {
            if i == selectedIndex {
                btn.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            } else {
                btn.layer?.backgroundColor = nil
            }
        }
    }

    // MARK: - Actions

    @objc private func toolButtonClicked(_ sender: NSButton) {
        let tools: [DrawingTool] = [.arrow, .rectangle, .circle]
        if sender.tag >= 0 && sender.tag < tools.count {
            annotationView.currentTool = tools[sender.tag]
            updateToolButtonStates(selectedIndex: sender.tag)
        }
    }

    @objc private func arrowStyleButtonClicked(_ sender: NSButton) {
        let styles = ArrowStyle.allPresets
        if sender.tag >= 0 && sender.tag < styles.count {
            annotationView.currentArrowStyle = styles[sender.tag]
            updateArrowStyleStates(selectedIndex: sender.tag)
        }
    }

    @objc private func colorButtonClicked(_ sender: NSButton) {
        let palette = ColorPalette.allPalettes[paletteIndex]
        if sender.tag >= 0 && sender.tag < palette.colors.count {
            annotationView.currentColor = palette.colors[sender.tag]
            // 更新选中边框
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
