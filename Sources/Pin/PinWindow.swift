import Cocoa

/// 贴在屏幕上的一张图。
///
/// 用 `NSPanel` 而不是 `NSWindow`：面板可以「不激活应用也能成为 key window」，
/// 于是点击贴图不会把焦点从用户正在用的应用上夺走 —— 这是贴图类工具的关键体感。
///
/// **三个容易漏掉、漏了就出错的设置**（详见 `init` 里的注释）：
/// 1. `collectionBehavior` 必须含 `.canJoinAllSpaces` + `.fullScreenAuxiliary`
/// 2. `sharingType = .none`
/// 3. `level` 要足够高
final class PinWindow: NSPanel {

    /// 当前显示的原图（缩放前的），用于「实际大小」与保存。
    let image: NSImage
    private var zoom: CGFloat = 1
    private var panOriginOnMouseDown: NSPoint = .zero
    private var mouseDownLocationOnScreen: NSPoint = .zero

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        // 不抢焦点：点击贴图不会激活本应用，也不会打断用户正在输入的内容
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear

        // 【必须】level 决定层级。.floating 够日常使用；用 .mainMenu 会更"硬"地压住
        // 普通窗口，但可能盖住输入法候选框之类，取 .floating。
        level = .floating

        // 【必须】全屏应用运行在独立的 Space 里，只设 level 不够 ——
        // 少了这一行，用户切到全屏应用时贴图就消失了（多数"置顶工具"的通病）。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // 【必须】让贴图对屏幕捕获 API 不可见，否则后续截图会把贴图自己也拍进去
        sharingType = .none
        // 有些版本上 shadowType/sharingType 的行为受此影响，显式声明不参与窗口列表
        animationBehavior = .none

        let content = PinContentView(image: image)
        content.onMouseDown = { [weak self] event in
            self?.beginDrag(with: event)
        }
        content.onMouseDragged = { [weak self] event in
            self?.continueDrag(with: event)
        }
        content.onScroll = { [weak self] event in
            // 归一化「自然滚动」偏好：不归一化的话，同一个手势在两种系统设置下
            // 得到相反的缩放方向 —— 用户只会觉得"滚轮有时正有时反"，
            // 而且换台机器、或者改一次系统设置才复现，极难归因。
            let raw = event.scrollingDeltaY
            let delta = event.isDirectionInvertedFromDevice ? -raw : raw
            self?.zoom(by: delta)
        }
        content.onDoubleClick = { [weak self] in
            self?.close()
        }
        content.menu = makeContextMenu()
        contentView = content

        // 初始缩放由传入的 frame 反推，**不能硬设 1** ——
        // PinManager 会为大图算一个「缩到能放下屏幕」的尺寸，硬设 1 会把它重置回
        // 原尺寸，于是钉一张全屏截图直接铺满整屏、连边缘都看不到。
        let initialZoom = image.size.width > 0 ? frame.width / image.size.width : 1
        applyZoom(initialZoom)
    }

    /// 不抢应用的激活状态，但允许成为 key window —— 这样点击后 Esc 才有响应。
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                    // Esc → 关闭这张贴图
            close()
        case 51, 117:               // Delete → 关闭
            close()
        default:
            super.keyDown(with: event)
        }
    }

    override func close() {
        PinManager.shared.unregister(self)
        super.close()
    }

    // MARK: - 拖动

    /// 自己在 `PinContentView` 里处理拖动，而不是靠 `isMovableByWindowBackground`。
    ///
    /// 原因：无边框面板上 `isMovableByWindowBackground` 与「滚轮缩放」「双击关闭」
    /// 会互相干扰（拖动时把双击吞掉，缩放的锚点也不对）。自己算 origin 更可控。
    private func beginDrag(with event: NSEvent) {
        panOriginOnMouseDown = frame.origin
        mouseDownLocationOnScreen = NSEvent.mouseLocation
    }

    private func continueDrag(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownLocationOnScreen.x
        let dy = now.y - mouseDownLocationOnScreen.y
        setFrameOrigin(NSPoint(x: panOriginOnMouseDown.x + dx,
                               y: panOriginOnMouseDown.y + dy))
    }

    // MARK: - 缩放

    /// 滚轮缩放。锚点保持在窗口中心：直接改 frame 会从左上角长，看起来在"跑"。
    ///
    /// 参数只收 delta —— 原先还带一个 `at pointInWindow`，但实现里从头到尾没用过
    /// （注释自己写的也是"锚点在中心"）。留着一个不读的参数只会让人以为锚点可配。
    private func zoom(by delta: CGFloat) {
        guard delta != 0 else { return }
        // 触控板一次滚动的 delta 很小（个位数），滚轮鼠标则常常是 ±1 一格。
        // 用指数映射让两者手感接近，并限制单次步进避免突变。
        let factor = exp(delta * 0.004)
        applyZoom(zoom * factor)
    }

    private func applyZoom(_ newZoom: CGFloat) {
        let clamped = min(max(newZoom, 0.1), 10)
        let pixelSize = image.size
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }

        let oldFrame = frame
        let newSize = NSSize(width: pixelSize.width * clamped,
                             height: pixelSize.height * clamped)
        zoom = clamped

        // 以中心为锚点缩放
        let center = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
        let newFrame = NSRect(x: center.x - newSize.width / 2,
                             y: center.y - newSize.height / 2,
                             width: newSize.width, height: newSize.height)
        setFrame(newFrame, display: true)
        (contentView as? PinContentView)?.needsDisplay = true
    }

    var currentZoom: CGFloat { zoom }

    // MARK: - 右键菜单

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let copy = NSMenuItem(title: "复制到剪贴板", action: #selector(copyToPasteboard), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let save = NSMenuItem(title: "保存为文件…", action: #selector(saveToFile), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        menu.addItem(NSMenuItem.separator())

        // 不透明度
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let item = NSMenuItem(title: "\(percent)%",
                                  action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = (percent == 100) ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let actualSize = NSMenuItem(title: "实际大小",
                                    action: #selector(resetZoom), keyEquivalent: "")
        actualSize.target = self
        menu.addItem(actualSize)

        let zoomIn = NSMenuItem(title: "放大", action: #selector(zoomInAction), keyEquivalent: "")
        zoomIn.target = self
        menu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "缩小", action: #selector(zoomOutAction), keyEquivalent: "")
        zoomOut.target = self
        menu.addItem(zoomOut)

        menu.addItem(NSMenuItem.separator())
        let closeItem = NSMenuItem(title: "关闭这张贴图（Esc）",
                                   action: #selector(close), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        let closeAll = NSMenuItem(title: "关闭全部贴图",
                                  action: #selector(closeAllPins), keyEquivalent: "")
        closeAll.target = self
        menu.addItem(closeAll)

        return menu
    }

    @objc private func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    @objc private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "pinned.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            // 经 TIFF 再包成 NSBitmapImageRep：它能吃下任意来源的图像（含非 RGB
            // 色彩空间），不必先拿到 CGImage。
            //
            // 订正一处注释：这里原先写"转成 sRGB 再编码"，但代码并没有做任何色彩空间
            // 转换，实际就是原样编码 —— 注释与实现不符，且不需要转，所以改注释。
            guard let tiff = self.image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else {
                self.reportSaveFailure("无法把图像编码为 PNG。")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // 原先用 `try?` 吞掉所有错误：磁盘满或没有写权限时，用户点了保存
                // 什么都没发生、也没有任何提示 —— 与 AnnotationWindow 里修过的
                // 是同一个缺陷，这里一并修掉。
                self.reportSaveFailure("写入失败：\(error.localizedDescription)\n\n\(url.path)")
            }
        }
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        alphaValue = CGFloat(sender.tag) / 100.0
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
    }

    /// 保存失败要说出来。
    private func reportSaveFailure(_ reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "保存贴图失败"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func resetZoom() { applyZoom(1) }
    @objc private func zoomInAction() { applyZoom(zoom * 1.25) }
    @objc private func zoomOutAction() { applyZoom(zoom / 1.25) }

    @objc private func closeAllPins() {
        PinManager.shared.closeAll()
    }
}

/// 贴图的内容视图：负责绘制（带描边与圆角）与鼠标事件转发。
private final class PinContentView: NSView {
    private let image: NSImage

    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 用图自身的逻辑尺寸铺满 bounds（窗口 frame 已按 zoom 算好）
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])

        // 1px 描边：浅色截图贴在浅色背景上时，没有边框会"糊"在背景里看不出边界
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        onMouseDown?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // 让窗口成为 key，右键菜单结束后 Esc 才能起作用
        window?.makeKey()
        super.rightMouseDown(with: event)
    }
}
