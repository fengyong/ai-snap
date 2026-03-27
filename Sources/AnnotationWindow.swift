import Cocoa

/// 标注窗口 — 包含工具栏和标注画布
class AnnotationWindow: NSWindow {
    private var annotationView: AnnotationView!
    private var toolButtons: [NSButton] = []

    init(image: NSImage) {
        let imageSize = image.size
        // 窗口大小 = 图片 + 底部工具栏
        let toolbarHeight: CGFloat = 44
        let windowSize = NSSize(width: max(imageSize.width, 420),
                                height: imageSize.height + toolbarHeight)

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

        // 标注画布
        annotationView = AnnotationView(image: image)
        annotationView.frame = NSRect(x: 0, y: toolbarHeight,
                                      width: imageSize.width, height: imageSize.height)
        container.addSubview(annotationView)

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

        var xOffset: CGFloat = 12

        // ── 工具选择 ──
        let tools: [(String, String)] = [
            ("↗", "箭头"),
            ("▭", "矩形"),
            ("○", "圆形"),
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
            xOffset += 36
        }

        // 默认选中箭头工具
        updateToolButtonStates(selectedIndex: 0)

        xOffset += 12

        // ── 分隔符 ──
        let sep2 = NSBox(frame: NSRect(x: xOffset, y: 6, width: 1, height: height - 12))
        sep2.boxType = .separator
        toolbar.addSubview(sep2)
        xOffset += 12

        // ── 颜色选择 ──
        let colors: [(NSColor, String)] = [
            (.systemRed, "红色"), (.systemBlue, "蓝色"),
            (.systemGreen, "绿色"), (.systemYellow, "黄色"),
        ]
        for (color, tip) in colors {
            let btn = NSButton(frame: NSRect(x: xOffset, y: 8, width: 28, height: 28))
            btn.bezelStyle = .circular
            btn.wantsLayer = true
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.cornerRadius = 14
            btn.toolTip = tip
            btn.target = self
            btn.action = #selector(colorButtonClicked(_:))
            btn.tag = colors.firstIndex(where: { $0.1 == tip }) ?? 0
            toolbar.addSubview(btn)
            xOffset += 36
        }

        xOffset += 12

        // ── 分隔符 ──
        let sep3 = NSBox(frame: NSRect(x: xOffset, y: 6, width: 1, height: height - 12))
        sep3.boxType = .separator
        toolbar.addSubview(sep3)
        xOffset += 12

        // ── 保存按钮 ──
        let saveBtn = NSButton(frame: NSRect(x: xOffset, y: 8, width: 60, height: 28))
        saveBtn.title = "保存"
        saveBtn.bezelStyle = .rounded
        saveBtn.target = self
        saveBtn.action = #selector(saveImage)
        toolbar.addSubview(saveBtn)
        xOffset += 68

        // ── 复制按钮 ──
        let copyBtn = NSButton(frame: NSRect(x: xOffset, y: 8, width: 60, height: 28))
        copyBtn.title = "复制"
        copyBtn.bezelStyle = .rounded
        copyBtn.target = self
        copyBtn.action = #selector(copyImage)
        toolbar.addSubview(copyBtn)

        return toolbar
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

    // MARK: - Actions

    @objc private func toolButtonClicked(_ sender: NSButton) {
        let tools: [DrawingTool] = [.arrow, .rectangle, .circle]
        if sender.tag >= 0 && sender.tag < tools.count {
            annotationView.currentTool = tools[sender.tag]
            updateToolButtonStates(selectedIndex: sender.tag)
        }
    }

    @objc private func colorButtonClicked(_ sender: NSButton) {
        let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow]
        if sender.tag >= 0 && sender.tag < colors.count {
            annotationView.currentColor = colors[sender.tag]
        }
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
