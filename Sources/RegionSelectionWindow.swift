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
            overlay.view.onInteractionStart = { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                // 同一时刻只有一个活动选区：本屏开始交互时，其余屏若还挂着
                // adjustable 选区就地清掉（覆盖层留着当压暗背景）——否则在 B 屏
                // 确认后，A 屏会留下一具带手柄的「选区尸体」画在冻结帧上。
                for other in self.overlays where other !== overlay {
                    other.view.discardPendingSelection()
                }
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

        // 选区吸附目标：此刻的窗口清单。覆盖层上屏前取（自家窗口未上屏、
        // 且 ownPID 本来就被排除），画面冻结后布局不再变，清单取一次即可。
        if Preferences.shared.snapSelectionToWindows,
           let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
           ) as? [[String: Any]] {
            let frames = WindowPickSupport.allWindowFrames(
                from: list,
                primaryScreenHeight: ScreenCapture.primaryScreenHeight,
                ownPID: ProcessInfo.processInfo.processIdentifier)
            for overlay in overlays {
                overlay.view.snapTargets = frames
                overlay.view.screenOrigin = overlay.screen.frame.origin
            }
        }

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
        // 确认屏之外不允许再有活动选区：其余屏若还挂着 adjustable 状态（比如
        // 用户在 A 屏松手、又去 B 屏双击确认），这里统一清掉，别让手柄和提示
        // 一直留在那块屏的冻结帧上。
        for other in overlays where other !== overlay {
            other.view.discardPendingSelection()
        }
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

/// 一块屏幕上的可交互覆盖层：画该屏冻结帧 + 变暗，并处理选区交互。
///
/// ## 选区状态机：idle → dragging → adjustable（可调整）→ 确认
///
/// 松手**不再立即确认**：有效选区进入 adjustable 态，选区留在屏上——
/// 拖选区内部整框移动、拖 8 个手柄缩放（角调两维、边调一维、对边锚定）、
/// 在选区外按下直接重选、方向键 ±1pt（Shift ±10pt）微调；
/// **双击 / Enter 才确认**进标注，Esc 退出整个覆盖层
/// （Snipaste 同款两步语义，2026-11-06 经产品确认）。
///
/// ## 为什么这个状态机长这样（真机翻车换来的）
///
/// 9-28 首版 adjusting（4874e9c）只改了时序、没给可供性：松手后画面纹丝不动，
/// 唯一的提示是一行小字，用户以为程序卡死——真机翻车，9da6f7b 整体撤下。
/// 教训**不是**「两步确认不能用」（Snipaste 用户天天在用），而是：
/// **改主流程时序，必须同时把可感知性做足**——手柄、光标变化、操作提示、
/// 移动/缩放/重选的真实手感，缺一样用户就会以为「松手没反应」重演。
class RegionSelectionView: NSView {
    var onSelectionComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    /// 本屏开始一次新的鼠标交互（任意 mouseDown）。协调器借此把**其余屏幕**上
    /// 还挂着的 adjustable 选区清掉：同一时刻只允许一个活动选区，否则在 B 屏
    /// 确认后，A 屏会留下一具带手柄和提示的「选区尸体」一直画在冻结帧上。
    var onInteractionStart: (() -> Void)?

    // MARK: 选区窗口吸附（见 SelectionSnapping）
    /// 吸附目标：冻结那一刻的全部可截窗口 frame（AppKit 全局坐标）。
    /// 画面已冻结，此刻的窗口布局就是用户看到的真相，之后不再重取。
    var snapTargets: [CGRect] = []
    /// 本屏原点（视图坐标 ↔ 全局坐标换算；吸附在全局空间做）
    var screenOrigin: CGPoint = .zero
    var snappingEnabled = true
    /// 当前被吸附到的窗口框（视图坐标；nil = 未吸附）。供绘制高亮。
    private var snappedWindowFrame: NSRect?

    /// 本屏的冻结帧。**不是可选装饰** —— 没有它，选区内部会露出真实屏幕，
    /// 而真实屏幕上的画面可能已经变了，看起来就像选区没生效。
    /// （多屏下某块屏冻结失败时它可为 nil：那块屏只压暗，见 freezeScreens 的降级说明。）
    var frozenImage: CGImage?

    private enum SelectionState {
        case idle
        case dragging(start: NSPoint)
        /// 松手后的可调整态：矩形有效，等移动 / 缩放 / 重选 / 确认
        case adjustable
        /// adjustable 中按住选区内部拖动：整框平移
        /// （original = 按下时的矩形，逐事件从它重算，不累积漂移）
        case moving(start: NSPoint, original: NSRect)
        /// adjustable 中按住手柄拖动：被拖边跟随光标、对边锚定
        case resizing(handle: SelectionHandle, original: NSRect)
    }
    private var state: SelectionState = .idle
    /// 当前画出来的矩形（dragging 中实时更新；adjustable 族态中被移动/缩放/微调）
    private var activeRect: NSRect?

    /// adjustable 族态（含移动/缩放进行中）：决定实线边框、手柄与操作提示是否绘制。
    private var isAdjusting: Bool {
        switch state {
        case .adjustable, .moving, .resizing: return true
        case .idle, .dragging: return false
        }
    }

    /// 探针观测点：adjustable 族态下的待确认矩形（nil = 不在该族态）。
    /// 离屏探针里 `needsDisplay` 不可观测（实测设 true 读回 false），
    /// 状态本身才是可靠的断言锚点。
    var pendingAdjustmentRect: NSRect? {
        guard isAdjusting else { return nil }
        return activeRect
    }

    private let dimAlpha: CGFloat = 0.35

    // MARK: 手柄几何

    /// 手柄方块边长（点，视觉尺寸）。
    private static let handleVisualSize: CGFloat = 8
    /// 手柄命中/光标容差（点）。8pt 的方块太小，按 ±6pt 扩大方形/边带命中区。
    private static let handleHitRadius: CGFloat = 6

    /// 选区缩放手柄：四角 + 四边。命名按**屏幕视觉方位**；视图坐标系 y 向上
    /// （原点在左下），`top` 边即 maxY 一侧。命中与光标矩形共用同一份 hitRect 几何。
    private enum SelectionHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// 手柄中心（视图坐标）：角 = 角点，边 = 边中点。
        func anchor(in rect: NSRect) -> NSPoint {
            switch self {
            case .topLeft:     return NSPoint(x: rect.minX, y: rect.maxY)
            case .top:         return NSPoint(x: rect.midX, y: rect.maxY)
            case .topRight:    return NSPoint(x: rect.maxX, y: rect.maxY)
            case .right:       return NSPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: return NSPoint(x: rect.maxX, y: rect.minY)
            case .bottom:      return NSPoint(x: rect.midX, y: rect.minY)
            case .bottomLeft:  return NSPoint(x: rect.minX, y: rect.minY)
            case .left:        return NSPoint(x: rect.minX, y: rect.midY)
            }
        }

        /// 手柄处的光标：角用十字（系统没有斜向 resize 光标），边用对应方向箭头。
        var cursor: NSCursor {
            switch self {
            case .left:   return .resizeLeft
            case .right:  return .resizeRight
            case .top:    return .resizeUp
            case .bottom: return .resizeDown
            default:      return .crosshair
            }
        }
    }

    /// 手柄命中区（视图坐标）：角 = 角点 ±handleHitRadius 的方形；
    /// 边 = 整条边带（垂直向 ±handleHitRadius、沿边向内缩 handleHitRadius 让角优先）。
    /// `handle(at:)` 与 `resetCursorRects` 共用这份几何——能点到的地方光标一定长得对。
    private static func hitRect(for handle: SelectionHandle, in rect: NSRect) -> NSRect {
        let r = handleHitRadius
        switch handle {
        case .topLeft:     return NSRect(x: rect.minX - r, y: rect.maxY - r, width: 2 * r, height: 2 * r)
        case .topRight:    return NSRect(x: rect.maxX - r, y: rect.maxY - r, width: 2 * r, height: 2 * r)
        case .bottomLeft:  return NSRect(x: rect.minX - r, y: rect.minY - r, width: 2 * r, height: 2 * r)
        case .bottomRight: return NSRect(x: rect.maxX - r, y: rect.minY - r, width: 2 * r, height: 2 * r)
        case .left:        return NSRect(x: rect.minX - r, y: rect.minY + r, width: 2 * r, height: rect.height - 2 * r)
        case .right:       return NSRect(x: rect.maxX - r, y: rect.minY + r, width: 2 * r, height: rect.height - 2 * r)
        case .top:         return NSRect(x: rect.minX + r, y: rect.maxY - r, width: rect.width - 2 * r, height: 2 * r)
        case .bottom:      return NSRect(x: rect.minX + r, y: rect.minY - r, width: rect.width - 2 * r, height: 2 * r)
        }
    }

    /// 手柄命中测试：角优先于边——边带整条可拖，但贴角 ±handleHitRadius 内角赢，
    /// 否则拖角会被边带抢先成单维调整。
    private static func handle(at p: NSPoint, for rect: NSRect) -> SelectionHandle? {
        let corners: [SelectionHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let edges: [SelectionHandle] = [.left, .right, .top, .bottom]
        for group in [corners, edges] {
            for handle in group {
                let hit = hitRect(for: handle, in: rect)
                if hit.width > 0, hit.height > 0, hit.contains(p) { return handle }
            }
        }
        return nil
    }

    /// 手柄缩放：被拖边跟随光标、对边锚定（轴对齐简化版，同标注 RectResizable 的思路）。
    /// 最小边长 `minSide` 钳制：光标越过对边时，被拖边钉在对边内侧 minSide 处，矩形不翻面。
    /// 光标先钳到 `bounds` 屏内——冻结帧按屏冻结，屏幕外没有内容可裁。
    private static func resized(_ original: NSRect, handle: SelectionHandle, to point: NSPoint,
                                minSide: CGFloat, in bounds: NSRect) -> NSRect {
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)

        var rect = original
        switch handle {
        case .topLeft, .bottomLeft, .left:
            // 拖 minX，maxX 锚定
            let edge = min(x, original.maxX - minSide)
            rect.origin.x = edge
            rect.size.width = original.maxX - edge
        case .topRight, .bottomRight, .right:
            // 拖 maxX，minX 锚定
            let edge = max(x, original.minX + minSide)
            rect.size.width = edge - original.minX
        case .top, .bottom:
            break
        }
        switch handle {
        case .bottomLeft, .bottom, .bottomRight:
            // 拖 minY，maxY 锚定（y 向上，bottom = minY）
            let edge = min(y, original.maxY - minSide)
            rect.origin.y = edge
            rect.size.height = original.maxY - edge
        case .topLeft, .top, .topRight:
            // 拖 maxY，minY 锚定
            let edge = max(y, original.minY + minSide)
            rect.size.height = edge - original.minY
        case .left, .right:
            break
        }
        return rect
    }

    override func mouseDown(with event: NSEvent) {
        // 本屏开始交互：协调器把其余屏幕挂着的 adjustable 选区清掉（见 onInteractionStart）
        onInteractionStart?()
        // 拖拽所在屏成为 key：拖拽过程中按 Esc 必须落在**这块屏**的视图上，
        // 而不是初始 key 的那块（用户可能换了屏开始拖拽）。
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)

        if case .adjustable = state, let rect = activeRect {
            // 双击落在 adjustable 态 = 确认（第一击松手已进 adjustable，第二击即确认）。
            // 必须在转移动/缩放/重拖之前判，否则第二击会莫名其妙开始一次新拖拽。
            if event.clickCount >= 2, rect.contains(p) {
                confirm(rect: rect)
                return
            }
            if let handle = Self.handle(at: p, for: rect) {
                // 手柄上按下 → 缩放（角调两维、边调一维）
                state = .resizing(handle: handle, original: rect)
            } else if rect.contains(p) {
                // 选区内部按下 → 整框移动
                state = .moving(start: p, original: rect)
            } else {
                // 选区外按下 → 重选：旧框作废，直接开始新一轮拖拽（Snipaste 同款）
                state = .dragging(start: p)
                activeRect = nil
                snappedWindowFrame = nil
            }
        } else {
            state = .dragging(start: p)
            activeRect = nil
            snappedWindowFrame = nil
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch state {
        case .dragging(let start):
            activeRect = snapped(rectFromPoints(start, p))
        case .moving(let start, let original):
            // 移动也吸附窗口边（Snipaste 同款「磁性」手感）：先钳屏再吸附——
            // 吸附目标都是屏内窗口，钳完的矩形才与它们处在同一几何关系里。
            activeRect = snapped(clampedToScreen(moved(original, from: start, to: p)))
        case .resizing(let handle, let original):
            // 缩放同样吸附：被拖边距窗口边 ≤8pt 时贴上去（SelectionSnapping 逐边决策）
            activeRect = snapped(Self.resized(original, handle: handle, to: p,
                                              minSide: Self.minimumSelectionSide, in: bounds))
        case .idle, .adjustable:
            break
        }
        needsDisplay = true
    }

    /// 选区矩形（视图坐标）→ 全局空间吸附 → 转回视图坐标。
    /// 顺带记录被吸附的窗口框（高亮用）；mouseDown 时会清掉。
    private func snapped(_ rect: NSRect) -> NSRect {
        guard snappingEnabled, !snapTargets.isEmpty else {
            snappedWindowFrame = nil
            return rect
        }
        let global = rect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)
        let (result, frame) = SelectionSnapping.snapped(global, toWindowFrames: snapTargets)
        snappedWindowFrame = frame?.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
        return result.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
    }

    /// 整框平移：尺寸不变。逐事件从 `original` 重算，不累积漂移。
    private func moved(_ original: NSRect, from start: NSPoint, to point: NSPoint) -> NSRect {
        original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
    }

    /// 把矩形原点钳回屏内（尺寸不变）。移动与方向键微调共用：
    /// 冻结帧按屏冻结，选区不允许移出本屏（Snipaste 同样限制在屏内）。
    private func clampedToScreen(_ rect: NSRect) -> NSRect {
        var r = rect
        r.origin.x = min(max(r.minX, bounds.minX), max(bounds.maxX - r.width, bounds.minX))
        r.origin.y = min(max(r.minY, bounds.minY), max(bounds.maxY - r.height, bounds.minY))
        return r
    }

    override func mouseUp(with event: NSEvent) {
        switch state {
        case .dragging:
            if let rect = activeRect {
                if rect.width > Self.minimumSelectionSide && rect.height > Self.minimumSelectionSide {
                    // 有效选区 → adjustable（可调整）态，**不**立即确认。
                    // 语义沿革：松手即确认是 9-30 真机翻车后恢复的；2026-11-06 产品
                    // 确认改回 Snipaste 两步语义——前提是手柄/光标/提示的可供性做足
                    // （上次翻车的根因是松手后画面毫无变化、又没有确认入口）。
                    state = .adjustable
                } else {
                    // 太小：以前是**静默什么都不做** —— 界面上没有任何反应，用户只会
                    // 以为截图坏了。给一声提示音，并保留覆盖层让用户重拖。
                    NSSound.beep()
                    state = .idle
                    activeRect = nil
                    snappedWindowFrame = nil
                }
            } else {
                // 单击（无拖拽）：安静回 idle，不留悬挂的 .dragging 态
                state = .idle
            }
        case .moving, .resizing:
            // 移动/缩放结束回到 adjustable，继续等确认或继续调整
            state = .adjustable
        case .idle, .adjustable:
            break
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape：任何状态都退出整个覆盖层
            // 重选不必经 Esc —— 在选区外拖即可（Snipaste 同款语义）
            state = .idle
            activeRect = nil
            snappedWindowFrame = nil
            onCancel?()
            return
        }
        guard case .adjustable = state, var rect = activeRect else { return }

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
        activeRect = clampedToScreen(rect)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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

        // 4. 边框：拖拽中虚线，adjustable 族态实线（一眼区分「还在拖」与「可调整」）
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        if !isAdjusting {
            ctx.setLineDash(phase: 0, lengths: [6, 3])
        }
        ctx.stroke(selectionRect)
        ctx.setLineDash(phase: 0, lengths: [])

        // 4.5 吸附高亮：被贴住的窗口描 accent 框，让"为什么选区自己动了"可见
        if let frame = snappedWindowFrame {
            let local = frame.intersection(bounds)
            if local.width > 0, local.height > 0 {
                ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(local)
            }
        }

        // 4.6 手柄（仅 adjustable 族态）：8 个白底黑边方块。
        //    这是「松手后有可调状态」的第一可供性 —— 上次翻车正是因为松手后
        //    画面与拖拽中毫无差别，用户不知道流程停在了哪一步。
        if isAdjusting {
            drawHandles(ctx: ctx, for: selectionRect)
        }

        // 5. 尺寸提示：贴在选区上方（太靠上时改放下方）；移动/缩放中实时刷新
        drawSizeLabel(ctx: ctx, for: selectionRect)

        // 6. 操作提示（仅 adjustable 族态）：与手柄、光标构成完整的证据链
        if isAdjusting {
            drawAdjustmentHint(ctx: ctx, for: selectionRect)
        }
    }

    /// 光标随位置变化：手柄上 resize 光标、选区内箭头、其余十字。
    /// 「松手后界面活了」的第二证据 —— 光标明确指出哪里能拖。
    /// （addCursorRect 只能在 resetCursorRects 里调用；后加的矩形优先，从外往内加。）
    override func resetCursorRects() {
        guard let rect = activeRect, isAdjusting else {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        addCursorRect(bounds, cursor: .crosshair)
        addCursorRect(rect, cursor: .arrow)
        for handle in SelectionHandle.allCases {
            let hit = Self.hitRect(for: handle, in: rect)
            guard hit.width > 0, hit.height > 0 else { continue }
            addCursorRect(hit, cursor: handle.cursor)
        }
    }

    /// 清掉本屏挂着的选区状态（协调器在「另一屏开始交互 / 某屏确认」时对其余屏调用）。
    /// 只清状态不动覆盖层：该屏继续当压暗背景，收层时一起 orderOut。
    func discardPendingSelection() {
        state = .idle
        activeRect = nil
        snappedWindowFrame = nil
        needsDisplay = true
    }

    /// 手柄：白底黑边小方块，中心落在 8 个锚点上。
    private func drawHandles(ctx: CGContext, for rect: NSRect) {
        let size = Self.handleVisualSize
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(1)
        for handle in SelectionHandle.allCases {
            let c = handle.anchor(in: rect)
            let box = NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
            ctx.fill(box)
            ctx.stroke(box)
        }
    }

    /// adjustable 族态的操作提示，贴在尺寸标签旁（同样有上/下两种落位）。
    /// 这行字与手柄、光标变化互为印证 —— 上次翻车的反面教训：只给这一行字
    /// 而没有手柄和交互，用户根本不知道流程停在了哪一步。
    private func drawAdjustmentHint(ctx: CGContext, for rect: NSRect) {
        let text = "拖动移动 · 拖边角缩放 · 选区外拖重选 · 双击/Enter 确认 · Esc 退出"
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

    /// 认为"这是一次有效选区"的最小边长（点）。
    ///
    /// 比它更小的拖拽按误触处理。这个数以前是散在 `mouseUp` 里的字面量 `5`，
    /// 现在抽出来，好让尺寸标签也能拿它给出"太小了"的可见提示。
    static let minimumSelectionSide: CGFloat = 5

    /// 确认选区（松手即确认的唯一路径；Esc 走 onCancel）
    private func confirm(rect: NSRect) {
        state = .idle
        activeRect = nil
        snappedWindowFrame = nil
        needsDisplay = true
        onSelectionComplete?(rect)
    }

    /// 尺寸提示：贴在选区上方（太靠上时改放下方）
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
