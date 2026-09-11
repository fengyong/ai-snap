import Cocoa

/// 全屏冰结覆盖层，用于区域选择。
///
/// **设计：先冻结屏幕，再在冻结帧上选区。**
///
/// 原实现是「先让用户拖框 → 关掉覆盖层 → 等 80ms → 再截图」，有两个后果：
/// 1. 必须等窗口服务器把覆盖层合成掉，否则覆盖层会被拍进图里 —— 于是有个
///    说不清道不明的魔法延迟，快一点慢一点都要靠试；
/// 2. 用户拖框时看到的是**活着的**屏幕（选区里是实时画面），拖的过程中内容会变。
///
/// 现在改成：显示覆盖层**之前**先把每块屏幕各截一张，覆盖层显示这张冻结图，
/// 用户看到的是静止画面。选区确定后只需要把冻结图**裁一刀** ——
/// 不调用捕获 API、不需要等待、也不会拍到覆盖层。
///
/// 多屏：每块屏各一张冻结图、各一个覆盖层；但只有主屏可交互（与原先一致）。
class RegionSelectionWindow: NSWindow {
    /// 选区完成时回调。
    ///
    /// 除了裁好的图，还回传**选区在 AppKit 屏幕坐标下的矩形** ——
    /// 调用方据此把标注窗口「就地」摆在选区上。图或矩形为 nil 表示取消 / 失败。
    private let completionHandler: (CGImage?, NSRect?) -> Void
    private var selectionView: RegionSelectionView!
    private var overlayWindows: [NSWindow] = []

    /// 主屏的冻结帧，选区确定后从它裁剪。
    private var frozenMainImage: CGImage?

    /// 交互屏（主屏）的框架，用于把视图坐标换算成屏幕坐标。
    private let mainScreenFrame: NSRect

    init(completion: @escaping (CGImage?, NSRect?) -> Void) {
        self.completionHandler = completion

        let screenFrame = NSScreen.main?.frame ?? .zero
        self.mainScreenFrame = screenFrame
        super.init(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // 冻结图会铺满整个窗口，所以不再需要半透明背景
        self.level = .statusBar + 1
        self.isOpaque = true
        self.backgroundColor = .black
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

        // 其他屏幕：各一个不可交互的覆盖层，同样画自己的冻结帧
        for screen in NSScreen.screens where screen != NSScreen.main {
            let overlay = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            overlay.level = .statusBar + 1
            overlay.isOpaque = true
            overlay.backgroundColor = .black
            overlay.hasShadow = false
            overlay.ignoresMouseEvents = true
            overlay.contentView = FrozenScreenView(frame: NSRect(origin: .zero, size: screen.frame.size))
            overlayWindows.append(overlay)
        }
    }

    /// 冻结屏幕。
    ///
    /// 必须在**显示覆盖层之前**调用，否则拍到的就是覆盖层自己。
    /// 返回 false 表示主屏冻结失败，调用方应放弃本次截屏（与旧流程的失败语义相同：
    /// 旧流程抓不到图同样只会得到 nil）。
    @discardableResult
    func freezeScreens() async -> Bool {
        guard let mainScreen = NSScreen.main else { return false }

        let mainImage = try? await ScreenCapture.captureRegion(ScreenCapture.quartzRect(for: mainScreen))
        guard let mainImage = mainImage else { return false }
        frozenMainImage = mainImage
        selectionView.frozenImage = mainImage

        for (index, screen) in NSScreen.screens.filter({ $0 != NSScreen.main }).enumerated() {
            guard index < overlayWindows.count else { break }
            let image = try? await ScreenCapture.captureRegion(ScreenCapture.quartzRect(for: screen))
            (overlayWindows[index].contentView as? FrozenScreenView)?.frozenImage = image
        }
        return true
    }

    func beginSelection() {
        // 从全局快捷键唤起时本应用并非前台，不主动激活的话覆盖层拿不到键盘焦点
        // （Esc 取消会失效、拖拽也可能不响应）。从菜单点进来时这行无害。
        NSApp.activate(ignoringOtherApps: true)

        makeKeyAndOrderFront(nil)
        for overlay in overlayWindows {
            overlay.orderFront(nil)
        }
        NSCursor.crosshair.push()
    }

    private func finishSelection(rect: NSRect) {
        // 视图坐标 → AppKit 屏幕坐标（覆盖层是无边框窗，视图原点即屏原点，但副屏可为负，
        // 所以显式偏移一次而不是假定主屏在 (0,0)）
        let screenRect = rect.offsetBy(dx: mainScreenFrame.minX, dy: mainScreenFrame.minY)

        // 不再立刻收掉覆盖层：它要留着当「就地编辑」的背景（周围保持变暗），
        // 等标注窗口关闭时由调用方调 hideOverlays() 收掉。
        // 但必须停止接收鼠标事件，否则它会挡住标注窗口的交互。
        stopInteracting()

        guard let frozen = frozenMainImage, let screen = NSScreen.main,
              let cropped = frozen.cropped(fromAppKitRect: screenRect, on: screen) else {
            hideOverlays()
            completionHandler(nil, nil)
            return
        }
        // 纯裁剪，没有异步等待 —— 这正是「先截后选」换来的收益
        completionHandler(cropped, screenRect)
    }

    private func cancelSelection() {
        hideOverlays()
        completionHandler(nil, nil)
    }

    /// 保留冻结画面，但不再吃鼠标事件。
    private func stopInteracting() {
        NSCursor.pop()
        ignoresMouseEvents = true
        for overlay in overlayWindows {
            overlay.ignoresMouseEvents = true
        }
    }

    /// 收掉全部覆盖层。标注窗口关闭时由 AppDelegate 调用。
    func hideOverlays() {
        NSCursor.pop()
        orderOut(nil)
        for overlay in overlayWindows {
            overlay.orderOut(nil)
        }
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - 冻结帧裁剪

extension CGImage {
    /// 从「整屏冻结图」里裁出 AppKit 选区。
    ///
    /// 换算逻辑在 `ScreenGeometry.pixelRect`（纯函数，已离屏测试）。
    func cropped(fromAppKitRect rect: NSRect, on screen: NSScreen) -> CGImage? {
        let pixelRect = ScreenGeometry.pixelRect(
            appKitRect: rect,
            imageSize: CGSize(width: width, height: height),
            appKitScreenFrame: screen.frame
        )
        guard !pixelRect.isNull else { return nil }
        return cropping(to: pixelRect)
    }
}

// MARK: - Selection View

/// 主屏的可交互覆盖层：画冻结帧 + 变暗，并处理拖拽选区。
class RegionSelectionView: NSView {
    var onSelectionComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    /// 本屏的冻结帧。**不是可选装饰** —— 没有它，选区内部会露出真实屏幕，
    /// 而真实屏幕上的画面可能已经变了，看起来就像选区没生效。
    var frozenImage: CGImage?

    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?

    private let dimAlpha: CGFloat = 0.35

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
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 冻结帧铺底
        if let frozen = frozenImage {
            ctx.draw(frozen, in: bounds)
        }

        // 2. 整体压暗一层
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        ctx.fill(bounds)

        guard let start = dragStart, let end = dragEnd else { return }
        let selectionRect = rectFromPoints(start, end)

        // 3. 选区内把冻结帧**再画一遍**（而不是用 .clear 挖洞）。
        //    挖洞会露出覆盖层后面的真实屏幕 —— 那就不是冻结画面了。
        ctx.saveGState()
        ctx.clip(to: selectionRect)
        if let frozen = frozenImage {
            ctx.draw(frozen, in: bounds)
        }
        ctx.restoreGState()

        // 4. 虚线边框
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 3])
        ctx.stroke(selectionRect)
        ctx.setLineDash(phase: 0, lengths: [])

        // 5. 尺寸提示：贴在选区上方（太靠上时改放下方）
        drawSizeLabel(ctx: ctx, for: selectionRect)
    }

    private func drawSizeLabel(ctx: CGContext, for rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let labelSize = NSSize(width: size.width + padding * 2, height: size.height + padding)

        var origin = NSPoint(x: rect.minX, y: rect.maxY + 4)
        if origin.y + labelSize.height > bounds.maxY {
            origin.y = rect.minY - labelSize.height - 4
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.maxX - labelSize.width, bounds.minX))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.maxY - labelSize.height, bounds.minY))

        let box = NSRect(origin: origin, size: labelSize)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.fill(box)
        (text as NSString).draw(
            at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attributes
        )
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

// MARK: - 非主屏覆盖层

/// 只负责把本屏的冻结帧画出来并压暗，不参与交互。
private final class FrozenScreenView: NSView {
    var frozenImage: CGImage?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let frozen = frozenImage {
            ctx.draw(frozen, in: bounds)
        }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)
    }
}
