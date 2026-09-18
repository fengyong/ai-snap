import Cocoa

/// 覆盖所有显示器的区域选择层。
///
/// 与旧实现的关键差别：
///  * **每块屏都有自己的覆盖窗口 + RegionSelectionView**，因此在任意显示器上都能拖拽选择
///    （旧实现只在 `NSScreen.main` 那块屏放了选区视图，其余屏的覆盖窗口是空的、只会吞掉鼠标事件）。
///  * 选区矩形换算基于**收到拖拽的那块屏**，不再丢屏幕原点、也不再用 `NSScreen.main` 当锚点。
///  * 截图用 `.optionOnScreenBelowWindow` + 覆盖层自身的窗口号，**不需要"先隐藏再 sleep"**。
class RegionSelectionWindow {

    /// 选区视图要求宿主窗口能成为 key（否则收不到 ESC）
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let completionHandler: (CaptureResult?) -> Void
    /// 窗口与屏幕成对保存：不依赖 `NSWindow.screen`（窗口未落屏或显示器睡眠时它会是 nil）
    private var overlays: [(window: OverlayWindow, screen: NSScreen)] = []
    private var finished = false

    init(completion: @escaping (CaptureResult?) -> Void) {
        self.completionHandler = completion
        buildOverlays()
    }

    private func buildOverlays() {
        for screen in NSScreen.screens {
            // 注意：**不要**给 NSWindow 传 `screen:` 参数。
            // 传了之后 AppKit 会把 contentRect 当成"相对该屏幕"的坐标，副屏的窗口原点
            // 会被再加一次屏幕原点（实测 (-803,-982) 变成 (-1606,-1964)），窗口被扔到
            // 所有显示器之外 —— 表现就是"3 块屏只有 1 块能框选"。
            // 只传全局坐标的 contentRect，让 AppKit 自己判断落在哪块屏。
            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: .borderless,
                                       backing: .buffered,
                                       defer: false)
            window.level = .statusBar + 1
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.3)
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false          // 交给 ARC 管理，避免 close() 后过度释放

            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screen = screen
            view.onSelectionComplete = { [weak self] rect, screen in
                self?.finishSelection(rect: rect, on: screen)
            }
            view.onCancel = { [weak self] in
                self?.cancelSelection()
            }
            window.contentView = view

            overlays.append((window, screen))
        }
    }

    func beginSelection() {
        for entry in overlays {
            entry.window.orderFrontRegardless()
        }
        // 让第一块屏的选区视图拿到键盘焦点（ESC 取消），并确保应用处于激活态
        NSApp.activate(ignoringOtherApps: true)
        if let first = overlays.first, let view = first.window.contentView {
            first.window.makeKey()
            first.window.makeFirstResponder(view)
        }
        NSCursor.crosshair.push()
    }

    /// 选区视图内坐标 → Quartz 坐标（左上角原点，锚定主显示器）。
    ///
    /// 纯函数，便于探针直接验证。**必须带上宿主屏幕的原点**：
    /// 旧实现直接用视图内 x/y，丢掉了 `screen.frame.origin`，在副屏上会截到另一块屏的区域。
    static func quartzRect(forViewRect rect: NSRect, on screen: NSScreen) -> CGRect {
        let global = CGRect(x: screen.frame.minX + rect.minX,
                            y: screen.frame.minY + rect.minY,
                            width: rect.width, height: rect.height)
        return CGRect(x: global.minX,
                      y: ScreenCapture.primaryDisplayHeight - global.maxY,
                      width: global.width, height: global.height)
    }

    /// 取消（ESC / 右键 / 外部打断）
    func cancelSelection() {
        guard !finished else { return }
        finished = true
        teardown()
        completionHandler(nil)
    }

    private func finishSelection(rect: NSRect, on screen: NSScreen) {
        guard !finished else { return }
        finished = true

        let quartz = RegionSelectionWindow.quartzRect(forViewRect: rect, on: screen)

        // 用覆盖层自身的窗口号做 below-window 截图：覆盖层（以及它之上的东西）不会被拍进去，
        // 因此无需等待窗口消失。
        let windowNumber = overlays.first { $0.screen === screen }
            .map { CGWindowID($0.window.windowNumber) }
        var image = ScreenCapture.captureRegion(quartz, belowWindow: windowNumber)

        if image == nil {
            // 回退路径不做 below-window 排除，会连压暗遮罩一起拍进去，
            // 所以必须**先撤掉覆盖层**再重试（原来的注释说"调用方保证覆盖层已隐藏"，
            // 但调用方其实是在截图之后才 teardown，注释与事实不符）。
            teardown()
            image = ScreenCapture.captureRegion(quartz, belowWindow: nil)
        }

        teardown()
        completionHandler(image.map { CaptureResult(image: $0, screen: screen) })
    }

    /// 撤掉所有覆盖窗口。**幂等**：重复调用不会重复 `NSCursor.pop()`。
    private func teardown() {
        guard !overlays.isEmpty else { return }
        NSCursor.pop()
        for entry in overlays {
            entry.window.orderOut(nil)
            entry.window.close()         // 从 NSApplication.windows 中摘掉，避免窗口残留
        }
        overlays.removeAll()
    }
}

// MARK: - Selection View

class RegionSelectionView: NSView {
    /// 本视图所属的屏幕（由 RegionSelectionWindow 注入）
    weak var screen: NSScreen?
    var onSelectionComplete: ((NSRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if event.type == .rightMouseDown { onCancel?(); return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragEnd = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart, let end = dragEnd else { return }
        let rect = rectFromPoints(start, end)
        dragStart = nil
        dragEnd = nil
        needsDisplay = true

        if rect.width > 5 && rect.height > 5, let screen = screen {
            onSelectionComplete?(rect, screen)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// 消息不会被送到 `cancelOperation(_:)`，这里显式处理一次，兼容其它取消手势
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// 应用未激活时，第一次点击会被当作"激活点击"吞掉 —— 覆写后即可直接开始选择
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let start = dragStart, let end = dragEnd else { return }

        let selectionRect = rectFromPoints(start, end)

        // 先把选区内部"挖空"，让下面的真实屏幕内容透出来；
        // 再描边 —— 否则 .clear 会把虚线边框的内半边一并擦掉（只留下 0.75pt）。
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(selectionRect)
        ctx.setBlendMode(.normal)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 3])
        ctx.stroke(selectionRect)
        ctx.restoreGState()
    }

    private func rectFromPoints(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        return NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
