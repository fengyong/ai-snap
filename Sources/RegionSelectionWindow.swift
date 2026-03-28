import Cocoa

/// 全屏半透明覆盖窗口，用于区域选择
class RegionSelectionWindow: NSWindow {
    private let completionHandler: (CGImage?) -> Void
    private var selectionView: RegionSelectionView!
    private var overlayWindows: [NSWindow] = []

    init(completion: @escaping (CGImage?) -> Void) {
        self.completionHandler = completion

        // 覆盖主屏幕
        let screenFrame = NSScreen.main?.frame ?? .zero
        super.init(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar + 1
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false

        selectionView = RegionSelectionView(frame: screenFrame)
        selectionView.onSelectionComplete = { [weak self] rect in
            self?.finishSelection(rect: rect)
        }
        selectionView.onCancel = { [weak self] in
            self?.cancelSelection()
        }
        self.contentView = selectionView

        // 为其他屏幕创建覆盖窗口
        for screen in NSScreen.screens where screen != NSScreen.main {
            let overlay = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            overlay.level = .statusBar + 1
            overlay.isOpaque = false
            overlay.backgroundColor = NSColor.black.withAlphaComponent(0.3)
            overlay.hasShadow = false
            overlayWindows.append(overlay)
        }
    }

    func beginSelection() {
        makeKeyAndOrderFront(nil)
        for overlay in overlayWindows {
            overlay.orderFront(nil)
        }
        NSCursor.crosshair.push()
    }

    private func finishSelection(rect: NSRect) {
        NSCursor.pop()
        orderOut(nil)
        for overlay in overlayWindows {
            overlay.orderOut(nil)
        }

        // NSView 坐标 → 屏幕坐标 (左上角原点，给 CGWindowList 用)
        let screenFrame = NSScreen.main?.frame ?? .zero
        let captureRect = CGRect(
            x: rect.origin.x,
            y: screenFrame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        // 延迟确保覆盖窗口完全消失后再截图
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let image = ScreenCapture.captureRegion(captureRect)
            self?.completionHandler(image)
        }
    }

    private func cancelSelection() {
        NSCursor.pop()
        orderOut(nil)
        for overlay in overlayWindows {
            overlay.orderOut(nil)
        }
        completionHandler(nil)
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Selection View

class RegionSelectionView: NSView {
    var onSelectionComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?

    override func mouseDown(with event: NSEvent) {
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

        if rect.width > 5 && rect.height > 5 {
            onSelectionComplete?(rect)
        }

        dragStart = nil
        dragEnd = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let start = dragStart, let end = dragEnd else { return }

        let selectionRect = rectFromPoints(start, end)

        // 半透明遮罩已由 window 背景提供，这里只画选区边框
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 3])
        ctx.stroke(selectionRect)

        // 选区内部清除遮罩效果（显示原始屏幕内容）
        ctx.setBlendMode(.clear)
        ctx.fill(selectionRect)
        ctx.setBlendMode(.normal)
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
