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
    /// 选区完成时回调。传 nil 表示取消 / 失败。
    ///
    /// 结果里除裁好的图，还带**选区在屏幕坐标下的矩形**（调用方据此把标注窗口
    /// 「就地」摆在选区上）与**实测的像素倍率**（见 `CapturedImage`）。
    private let completionHandler: (CapturedImage?) -> Void
    private var selectionView: RegionSelectionView!
    private var overlayWindows: [NSWindow] = []

    /// 主屏的冻结帧，选区确定后从它裁剪。
    private var frozenMainImage: CGImage?

    /// 交互屏（主屏）的框架，用于把视图坐标换算成屏幕坐标。
    private let mainScreenFrame: NSRect
    /// 交互屏本身。**init 时冻结一次**，之后全程复用。
    ///
    /// 不能每次要用时重取 `NSScreen.main`：它的语义是"当前 key window 所在屏"，
    /// 而覆盖层上屏后自己就成了 key window —— 之后再取可能换了一块屏。
    /// 冻结帧、副屏枚举、坐标换算必须锚在同一块屏上。
    private let mainScreen: NSScreen?
    /// 光标是否已 push（用于让 pop 幂等，见 restoreCursorIfNeeded）
    private var cursorPushed = false
    private var cursorRestored = false

    init(completion: @escaping (CapturedImage?) -> Void) {
        self.completionHandler = completion

        // 只取一次 NSScreen.main，屏幕对象与它的 frame 都从这里派生
        let screen = NSScreen.main
        self.mainScreen = screen
        let screenFrame = screen?.frame ?? .zero
        self.mainScreenFrame = screenFrame
        super.init(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // 窗口外观交给 OverlayWindowStyle（关键点是**背景透明而非纯黑**：
        // 冻结帧画好之前透出的是真实屏幕，若是纯黑就会全屏黑闪。见那里的说明）
        OverlayWindowStyle.apply(to: self)
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true

        selectionView = RegionSelectionView(frame: screenFrame)
        selectionView.onSelectionComplete = { [weak self] rect in
            self?.finishSelection(rect: rect)
        }
        selectionView.onCancel = { [weak self] in
            self?.cancelSelection()
        }
        self.contentView = selectionView

        // 其他屏幕：各一个不可交互的覆盖层，同样画自己的冻结帧
        for screen in NSScreen.screens where screen !== mainScreen {
            let overlay = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            // 与主屏覆盖层共用同一份外观配置（透明背景的理由见 OverlayWindowStyle）
            OverlayWindowStyle.apply(to: overlay)
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
        // 用 init 时冻结下来的那块屏，而不是此刻重取 NSScreen.main：
        // 覆盖层上屏后自己是 key window，重取可能换屏，导致"冻结的是 A 屏、
        // 坐标按 B 屏算"这类错位（副屏 Y 翻转 bug 与此同源）。
        guard let targetScreen = mainScreen else { return false }

        let mainImage = try? await ScreenCapture.captureRegion(ScreenCapture.quartzRect(for: targetScreen))
        guard let mainImage = mainImage else { return false }
        frozenMainImage = mainImage
        selectionView.frozenImage = mainImage

        for (index, screen) in NSScreen.screens.filter({ $0 !== targetScreen }).enumerated() {
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

        // 上屏之后补一次同步绘制，让「冻结帧 + 变暗」尽早出现。
        // 顺序不能反过来：**未上屏的窗口没有 window device**，实测那时
        // `display()` / `displayIfNeeded()` 都是 no-op（draw 根本不被调用）。
        // 窗口是透明的，所以即便这一帧迟到，用户看到的也只是「还没变暗的真实屏幕」，
        // 不会有黑闪 —— 这次调用只是把变暗提前，不是正确性的前提。
        selectionView.display()
        for overlay in overlayWindows {
            overlay.contentView?.display()
        }

        NSCursor.crosshair.push()
        cursorPushed = true
        cursorRestored = false
    }

    private func finishSelection(rect: NSRect) {
        // 视图坐标 → AppKit 屏幕坐标（覆盖层是无边框窗，视图原点即屏原点，但副屏可为负，
        // 所以显式偏移一次而不是假定主屏在 (0,0)）
        let screenRect = rect.offsetBy(dx: mainScreenFrame.minX, dy: mainScreenFrame.minY)

        // 不再立刻收掉覆盖层：它要留着当「就地编辑」的背景（周围保持变暗），
        // 等标注窗口关闭时由调用方调 hideOverlays() 收掉。
        // 但必须停止接收鼠标事件，否则它会挡住标注窗口的交互。
        stopInteracting()

        // 用 **init 时存下的** mainScreenFrame，而不是此刻再取 NSScreen.main ——
        // 后者的定义是"当前 key window 所在屏"，冻结帧之后覆盖层成了 key window，
        // 取值可能与冻屏时不是同一块屏（这与之前修掉的副屏 Y 翻转 bug 同源）。
        guard let frozen = frozenMainImage,
              let cropped = frozen.cropped(fromAppKitRect: screenRect,
                                           screenFrame: mainScreenFrame) else {
            hideOverlays()
            completionHandler(nil)
            return
        }
        // 纯裁剪，没有异步等待 —— 这正是「先截后选」换来的收益
        //
        // 倍率在这里**按实际尺寸反推**（冻结图像素宽 ÷ 屏幕点宽），随后一路传到标注窗口。
        // 于是裁剪与显示两侧用的是同一个数：即便捕获返回的分辨率与屏幕倍率不符，
        // 画布尺寸仍然与选区像素严格对应，不会出现"画布缩成选区一半"。
        completionHandler(CapturedImage(
            image: cropped,
            pixelScale: CapturedImage.scale(pixelWidth: frozen.width,
                                            pointWidth: mainScreenFrame.width),
            anchorRect: screenRect))
    }

    private func cancelSelection() {
        hideOverlays()
        completionHandler(nil)
    }

    /// 保留冻结画面，但不再吃鼠标事件。
    private func stopInteracting() {
        restoreCursorIfNeeded()
        ignoresMouseEvents = true
        for overlay in overlayWindows {
            overlay.ignoresMouseEvents = true
        }
    }

    /// 收掉全部覆盖层。标注窗口关闭时由 AppDelegate 调用。
    func hideOverlays() {
        restoreCursorIfNeeded()
        orderOut(nil)
        for overlay in overlayWindows {
            overlay.orderOut(nil)
        }
    }

    /// 还原为十字光标之前的光标。**幂等**。
    ///
    /// 成功路径上 `stopInteracting()`（选区确定，转去标注）与 `hideOverlays()`
    /// （标注窗口关闭）会先后各调一次，而 push 只发生在上屏时那一次 ——
    /// 不做保护就会多 pop 一次，把栈里别人的光标弹掉，
    /// 表现为"用完截图后系统光标变成了别的样子"。
    private func restoreCursorIfNeeded() {
        guard cursorPushed, !cursorRestored else { return }
        NSCursor.pop()
        cursorRestored = true
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - 冻结帧裁剪

extension CGImage {
    /// 从「整屏冻结图」里裁出 AppKit 选区。
    ///
    /// 换算逻辑在 `ScreenGeometry.pixelRect`（纯函数，已离屏测试）。
    /// 参数是**屏幕矩形**而不是 `NSScreen`：调用方应当把它在冻屏时记下的那块屏的
    /// frame 传进来，而不是在这里重新取 `NSScreen.main`（那可能已经换了一块屏）。
    func cropped(fromAppKitRect rect: NSRect, screenFrame: NSRect) -> CGImage? {
        let pixelRect = ScreenGeometry.pixelRect(
            appKitRect: rect,
            imageSize: CGSize(width: width, height: height),
            appKitScreenFrame: screenFrame
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

        if rect.width > Self.minimumSelectionSide && rect.height > Self.minimumSelectionSide {
            onSelectionComplete?(rect)
        } else {
            // 太小：以前是**静默什么都不做** —— 界面上没有任何反应，用户只会以为截图坏了。
            // 给一声提示音，并保留覆盖层让用户重拖（不销毁状态，直接再来一次即可）。
            NSSound.beep()
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

    /// 认为"这是一次有效选区"的最小边长（点）。
    ///
    /// 比它更小的拖拽按误触处理。这个数以前是散在 `mouseUp` 里的字面量 `5`，
    /// 现在抽出来，好让尺寸标签也能拿它给出"太小了"的可见提示。
    static let minimumSelectionSide: CGFloat = 5

    private func drawSizeLabel(ctx: CGContext, for rect: NSRect) {
        // 小于阈值的选区会被 mouseUp 拒收，所以标签上要说清"为什么点了没反应"
        let tooSmall = rect.width <= Self.minimumSelectionSide
            || rect.height <= Self.minimumSelectionSide
        let side = Int(Self.minimumSelectionSide)
        let text = tooSmall
            ? "\(Int(rect.width)) × \(Int(rect.height))　太小，至少 \(side) × \(side)"
            : "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: tooSmall ? NSColor.systemOrange : NSColor.white,
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
