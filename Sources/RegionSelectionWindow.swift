import Cocoa

/// 多屏冻结覆盖层协调器，用于区域选择。
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
/// **多屏（对等交互）**：每块屏各一个交互覆盖层，鼠标在哪块屏上按下拖拽，
/// 那块屏就是本次的选区屏 —— 选区矩形、冻结帧裁剪、就地标注的 `anchorRect`
/// 全部锚定它，其余屏幕保持「冻结 + 压暗」当背景。此前只有主屏可交互、
/// 副屏仅遮罩（半成品）。鼠标拖拽天然跟随 `mouseDown` 落在的那个 view
/// （AppKit 在 mouseDown 之后把后续 drag/up 事件派发给同一 view），多屏之间
/// 不存在竞态；坐标换算全部走 `ScreenGeometry` 的纯函数（它们本就接受任意
/// screenFrame，含负坐标），这是当初把「换算」与「交互」拆开时买下的保险。
///
/// 协调器自身不是窗口：它只持有每屏一个的覆盖层窗口并裁决「谁赢了」。
final class RegionSelectionWindow: NSObject {
    /// 选区完成时回调。传 nil 表示取消 / 失败。
    ///
    /// 结果里除裁好的图，还带**选区在屏幕坐标下的矩形**（调用方据此把标注窗口
    /// 「就地」摆在选区上，且落点锚定选区所在的那块屏）与**实测的像素倍率**。
    private let completionHandler: (CapturedImage?) -> Void

    private var overlays: [ScreenOverlay] = []

    /// 光标是否已 push（用于让 pop 幂等，见 restoreCursorIfNeeded）
    private var cursorPushed = false
    private var cursorRestored = false

    /// 一块屏的覆盖层：窗口 + 选区视图。
    ///
    /// 三者绑定在一起，选区屏的判定（谁赢了）就不再依赖任何「主屏」概念。
    /// 屏幕对象在 init 时冻结 —— 覆盖层上屏后 `NSScreen.main` 会变
    /// （它的语义是「当前 key window 所在屏」），不能到用时再取。
    private final class ScreenOverlay {
        let window: RegionOverlayWindow
        let view: RegionSelectionView
        let screen: NSScreen

        var frozenImage: CGImage? {
            get { view.frozenImage }
            set { view.frozenImage = newValue }
        }

        init(screen: NSScreen) {
            self.screen = screen
            let window = RegionOverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            // 所有屏共用同一份外观配置（透明背景防黑闪的理由见 OverlayWindowStyle）
            OverlayWindowStyle.apply(to: window)
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            self.window = window
            self.view = view
        }
    }

    init(completion: @escaping (CapturedImage?) -> Void) {
        self.completionHandler = completion
        super.init()

        for screen in NSScreen.screens {
            let overlay = ScreenOverlay(screen: screen)
            overlay.view.onSelectionComplete = { [weak self, weak overlay] rect in
                guard let self, let overlay else { return }
                self.finishSelection(overlay: overlay, rect: rect)
            }
            overlay.view.onCancel = { [weak self] in
                self?.cancelSelection()
            }
            overlays.append(overlay)
        }
    }

    /// 冻结所有屏幕。
    ///
    /// 必须在**显示覆盖层之前**调用，否则拍到的就是覆盖层自己。
    /// 目标屏 = 光标所在屏（用户最可能直接在那里开始拖拽）：它失败 → 整体放弃
    /// （与旧流程「主屏失败即失败」同语义，只是判定基准从「主屏」换成「光标屏」）；
    /// 其余屏失败 → 该屏覆盖层只压暗不冻结（透出的是真实屏幕，降级但可用，
    /// 比整个截图失败好 —— 极少见，通常是那块屏恰好在权限/睡眠边界上）。
    @discardableResult
    func freezeScreens() async -> Bool {
        guard !overlays.isEmpty else { return false }

        let mouseLocation = NSEvent.mouseLocation
        let target = overlays.first { $0.screen.frame.contains(mouseLocation) } ?? overlays[0]
        let others = overlays.filter { $0 !== target }

        for overlay in [target] + others {
            let image = try? await ScreenCapture.captureRegion(ScreenCapture.quartzRect(for: overlay.screen))
            overlay.frozenImage = image
            if overlay === target && image == nil { return false }
        }
        return true
    }

    func beginSelection() {
        // 从全局快捷键唤起时本应用并非前台，不主动激活的话覆盖层拿不到键盘焦点
        // （Esc 取消会失效、拖拽也可能不响应）。从菜单点进来时这行无害。
        NSApp.activate(ignoringOtherApps: true)

        // 初始 key 窗 = 光标所在屏：用户在副屏上按热键之后直接按 Esc 必须生效，
        // 不该要求先点一下那块屏。后续 mouseDown 会把拖拽屏再设为 key（见视图）。
        let mouseLocation = NSEvent.mouseLocation
        let keyOverlay = overlays.first { $0.screen.frame.contains(mouseLocation) } ?? overlays.first

        for overlay in overlays {
            overlay.window.orderFront(nil)
            // 上屏之后补一次同步绘制，让「冻结帧 + 变暗」尽早出现。
            // 顺序不能反过来：**未上屏的窗口没有 window device**，实测那时
            // `display()` / `displayIfNeeded()` 都是 no-op（draw 根本不被调用）。
            // 窗口是透明的，所以即便这一帧迟到，用户看到的也只是「还没变暗的真实屏幕」，
            // 不会有黑闪 —— 这次调用只是把变暗提前，不是正确性的前提。
            overlay.view.display()
        }
        keyOverlay?.window.makeKey()

        NSCursor.crosshair.push()
        cursorPushed = true
        cursorRestored = false
    }

    /// 选区在某块屏上完成：从**那块屏**的冻结帧裁剪。
    ///
    /// 视图坐标 → AppKit 屏幕坐标：覆盖层是无边框窗、视图原点即屏原点，
    /// 而副屏原点可为负，所以显式偏移该屏的 frame（init 时冻结的那块屏对象，
    /// 不是此刻重取 —— 后者可能换屏，见 ScreenOverlay 的说明）。
    private func finishSelection(overlay: ScreenOverlay, rect: NSRect) {
        let screenRect = rect.offsetBy(dx: overlay.screen.frame.minX, dy: overlay.screen.frame.minY)

        // 不再立刻收掉覆盖层：它们要留着当「就地编辑」的背景（周围保持变暗），
        // 等标注窗口关闭时由调用方调 hideOverlays() 收掉。
        // 但必须停止接收鼠标事件，否则会挡住标注窗口的交互。
        stopInteracting()

        guard let frozen = overlay.frozenImage,
              let cropped = frozen.cropped(fromAppKitRect: screenRect,
                                           screenFrame: overlay.screen.frame) else {
            hideOverlays()
            completionHandler(nil)
            return
        }
        // 纯裁剪，没有异步等待 —— 这正是「先截后选」换来的收益
        //
        // 倍率在这里**按实际尺寸反推**（该屏冻结图像素宽 ÷ 该屏点宽），随后一路传到标注窗口。
        // 于是裁剪与显示两侧用的是同一个数：即便捕获返回的分辨率与屏幕倍率不符，
        // 画布尺寸仍然与选区像素严格对应，不会出现"画布缩成选区一半"。
        // 注意倍率按**选区屏**算：副屏与主屏的 Retina 倍率可以不同。
        completionHandler(CapturedImage(
            image: cropped,
            pixelScale: CapturedImage.scale(pixelWidth: frozen.width,
                                            pointWidth: overlay.screen.frame.width),
            anchorRect: screenRect))
    }

    private func cancelSelection() {
        hideOverlays()
        completionHandler(nil)
    }

    /// 保留冻结画面，但不再吃鼠标事件。
    private func stopInteracting() {
        restoreCursorIfNeeded()
        for overlay in overlays {
            overlay.window.ignoresMouseEvents = true
        }
    }

    /// 收掉全部覆盖层。标注窗口关闭时由 AppDelegate 调用。
    func hideOverlays() {
        restoreCursorIfNeeded()
        for overlay in overlays {
            overlay.window.orderOut(nil)
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
}

/// 单块屏幕的覆盖层窗口。每屏一个、彼此对等（多屏选区后不再有"主窗"）。
final class RegionOverlayWindow: NSWindow {
    // 无边框窗默认不能成为 key window；不能成为 key 就收不到键盘事件，
    // Esc 取消会失效 —— 与原先主覆盖层的处理一致。
    override var canBecomeKey: Bool { true }
}

// MARK: - 冻结帧裁剪

extension CGImage {
    /// 从「整屏冻结图」里裁出 AppKit 选区。
    ///
    /// 换算逻辑在 `ScreenGeometry.pixelRect`（纯函数，已离屏测试，含负坐标副屏案例）。
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

/// 一块屏幕上的可交互覆盖层：画该屏冻结帧 + 变暗，并处理拖拽选区。
///
/// ## 选区状态机：idle → dragging → adjusting → 确认
///
/// `mouseUp` 不再立即确认：有效选区进入 **adjusting（待确认）** —— 方向键整框
/// 微调（±1px，Shift ±10px）、再拖 = 重选、Enter / 双击确认、Esc 取消。
/// 之前松手即定，差 1px 也只能整张重截；键盘微调是「不用回鼠标就能对齐」的
/// 最后一步（与标注画布「全程不碰鼠标」的键盘闭环同一设计取向）。
class RegionSelectionView: NSView {
    var onSelectionComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    /// 本屏的冻结帧。**不是可选装饰** —— 没有它，选区内部会露出真实屏幕，
    /// 而真实屏幕上的画面可能已经变了，看起来就像选区没生效。
    /// （多屏下某块屏冻结失败时它可为 nil：那块屏只压暗，见 freezeScreens 的降级说明。）
    var frozenImage: CGImage?

    private enum SelectionState {
        case idle
        case dragging(start: NSPoint)
        /// 松手后的待确认态：矩形已有效，等微调 / 确认 / 重拖
        case adjusting
    }
    private var state: SelectionState = .idle
    /// 当前画出来的矩形（dragging 中实时更新；adjusting 中被方向键挪动）
    private var activeRect: NSRect?

    /// 探针观测点：adjusting 态的待确认矩形（nil = 不在该状态）。
    /// 离屏探针里 `needsDisplay` 不可观测，状态本身才是可靠的断言锚点。
    var pendingAdjustmentRect: NSRect? {
        guard case .adjusting = state else { return nil }
        return activeRect
    }

    private let dimAlpha: CGFloat = 0.35

    override func mouseDown(with event: NSEvent) {
        // 拖拽所在屏成为 key：拖拽过程中按 Esc 必须落在**这块屏**的视图上，
        // 而不是初始 key 的那块（用户可能换了屏开始拖拽）。
        window?.makeKey()
        // 双击落在 adjusting 态 = 确认（第一击进入待确认、第二击即确认）。
        // 必须在转 dragging 之前判，否则第二击会莫名其妙开始一次新拖拽。
        if case .adjusting = state, event.clickCount >= 2 {
            if let rect = activeRect { confirm(rect: rect) }
            return
        }
        state = .dragging(start: convert(event.locationInWindow, from: nil))
        activeRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .dragging(let start) = state else { return }
        activeRect = rectFromPoints(start, convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard case .dragging = state, let rect = activeRect else { return }

        if rect.width > Self.minimumSelectionSide && rect.height > Self.minimumSelectionSide {
            // 有效选区 → 待确认（不立即确认，留出微调余地）
            state = .adjusting
        } else {
            // 太小：以前是**静默什么都不做** —— 界面上没有任何反应，用户只会以为截图坏了。
            // 给一声提示音，并保留覆盖层让用户重拖（不销毁状态，直接再来一次即可）。
            NSSound.beep()
            state = .idle
            activeRect = nil
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape：任何状态都取消
            state = .idle
            activeRect = nil
            onCancel?()
            return
        }
        guard case .adjusting = state, var rect = activeRect else { return }

        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: rect.origin.x -= step          // ←
        case 124: rect.origin.x += step          // →
        case 125: rect.origin.y -= step          // ↓（AppKit y 轴向上，向下是减）
        case 126: rect.origin.y += step          // ↑
        case 36, 52:                             // Return / 小键盘 Enter → 确认
            confirm(rect: rect)
            return
        default:
            return
        }
        activeRect = rect
        needsDisplay = true
    }

    private func confirm(rect: NSRect) {
        state = .idle
        activeRect = nil
        needsDisplay = true
        onSelectionComplete?(rect)
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

        guard let selectionRect = activeRect else { return }

        // 3. 选区内把冻结帧**再画一遍**（而不是用 .clear 挖洞）。
        //    挖洞会露出覆盖层后面的真实屏幕 —— 那就不是冻结画面了。
        ctx.saveGState()
        ctx.clip(to: selectionRect)
        if let frozen = frozenImage {
            ctx.draw(frozen, in: bounds)
        }
        ctx.restoreGState()

        // 4. 虚线边框（待确认态用实线：一眼区分「还在拖」与「等确认」）
        var adjusting = false
        if case .adjusting = state { adjusting = true }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        if !adjusting {
            ctx.setLineDash(phase: 0, lengths: [6, 3])
        }
        ctx.stroke(selectionRect)
        ctx.setLineDash(phase: 0, lengths: [])

        // 5. 尺寸提示：贴在选区上方（太靠上时改放下方）
        drawSizeLabel(ctx: ctx, for: selectionRect)
        // 6. 待确认提示（只在该态出现一次，不常驻打扰）
        if adjusting {
            drawConfirmHint(ctx: ctx, for: selectionRect)
        }
    }

    /// 认为"这是一次有效选区"的最小边长（点）。
    ///
    /// 比它更小的拖拽按误触处理。这个数以前是散在 `mouseUp` 里的字面量 `5`，
    /// 现在抽出来，好让尺寸标签也能拿它给出"太小了"的可见提示。
    static let minimumSelectionSide: CGFloat = 5

    /// 待确认态的操作提示，贴在尺寸标签旁（同样有上/下两种落位）。
    private func drawConfirmHint(ctx: CGContext, for rect: NSRect) {
        let text = "Enter 确认 · 方向键微调 · Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let box = NSSize(width: size.width + padding * 2, height: size.height + padding)

        var origin = NSPoint(x: rect.minX, y: rect.maxY + 26)
        if origin.y + box.height > bounds.maxY {
            origin.y = rect.minY - box.height - 22
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.maxX - box.width, bounds.minX))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.maxY - box.height, bounds.minY))

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.fill(NSRect(origin: origin, size: box))
        (text as NSString).draw(
            at: NSPoint(x: origin.x + padding, y: origin.y + padding / 2),
            withAttributes: attributes
        )
    }

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
