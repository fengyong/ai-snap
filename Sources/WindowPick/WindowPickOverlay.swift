import Cocoa

/// 窗口选择模式：全屏透明覆盖层上实时高亮光标下的窗口，单击确认截取。
///
/// ## 为什么消灭了 0.5 秒延迟
///
/// 旧实现是「点菜单 / 按热键 → 等 0.5 秒 → 截当前鼠标下的窗口」——用户必须在这
/// 0.5 秒里切到目标窗口，是在和定时器赛跑；全局热键路径更别扭：得先悬停好再按键。
/// 选择模式把这个时序 hack 整个拿掉：先**看到**要哪个（高亮跟随 + 滚轮换选重叠窗），
/// 再单击确认。
///
/// ## 为什么不需要冻结屏幕
///
/// 区域截图必须冻结（覆盖层不能被拍进图里）；窗口截图不需要 —— 确认后走
/// `SCContentFilter(desktopIndependentWindow:)`，SCK 抓的是**窗口自身**的离屏内容，
/// 自家覆盖层（ownPID 排除）根本进不了图。用户看着活着的窗口做选择反而更好：
/// 视频还在播、终端还在滚，选的就是「现在这个窗口」。
///
/// ## 事件模型
///
/// 全部交互走一个 **local 事件监视器**：mouseMoved 只派发给 key window（恰好全屏
/// 覆盖层就是 key），滚轮/点击派发给光标下的窗口（也是我们的覆盖层），于是监视器
/// 能看到所有事件并统一吞掉，覆盖层 view 因此只负责绘制、不碰事件。
/// 光标换屏时把那块屏的覆盖层设为 key，保证 Esc 永远有人接。
final class WindowPickOverlay: NSObject {
    /// 确认时带回窗口 ID；nil = 取消（Esc / 右键 / 点击桌面空白处）。
    private let completionHandler: (CGWindowID?) -> Void

    /// 一块屏一个覆盖层；彼此对等，光标在哪块屏就高亮/确认那块屏视野里的窗口。
    private final class ScreenLayer {
        let window: NSWindow
        let view: WindowPickView

        init(screen: NSScreen) {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            OverlayWindowStyle.apply(to: window)
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            let view = WindowPickView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            window.contentView = view
            self.window = window
            self.view = view
        }
    }

    private var layers: [ScreenLayer] = []
    private var monitor: Any?
    private var cursorPushed = false

    /// 光标处的候选（按 Z 序）与滚轮换选的下标；空列表 = 光标下没有可截窗口（桌面）。
    private var candidates: [WindowPickSupport.Candidate] = []
    private var candidateIndex: Int?
    /// 命中判定节流：光标挪动不足 2pt 不重新枚举窗口（CGWindowListCopyWindowInfo
    /// 每次都要过 Window Server，mouseMoved 的触发频率远高于需要）。
    private var lastTestPoint = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)

    init(completion: @escaping (CGWindowID?) -> Void) {
        self.completionHandler = completion
        super.init()
        for screen in NSScreen.screens {
            layers.append(ScreenLayer(screen: screen))
        }
    }

    func begin() {
        NSApp.activate(ignoringOtherApps: true)

        for layer in layers {
            layer.window.orderFront(nil)
            layer.view.display()
        }
        // 初始 key 窗 = 光标所在屏：按热键后直接按 Esc 必须生效，不该要求先点一下。
        let mouseLocation = NSEvent.mouseLocation
        let keyLayer = layers.first { $0.window.frame.contains(mouseLocation) } ?? layers.first
        keyLayer?.window.makeKey()

        NSCursor.pointingHand.push()
        cursorPushed = true

        // 光标可能已经悬在目标窗口上：立即高亮一次，不等第一个 mouseMoved
        refreshHighlight(force: true)

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            self?.handle(event)
            return nil   // 全部吞掉：选择模式是模态的，覆盖层之下不该有人收到事件
        }
    }

    /// 主动收场（外部要求取消时用，例如同时发起了区域截图）。
    /// 与「用户取消」走同一条完成路径，保证引用/光标/监视器只清一次。
    func cancel() {
        finish(nil)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            refreshHighlight(force: false)
        case .scrollWheel:
            // 滚轮在重叠窗口间换选：下滚回到 Z 序更靠前的，上滚往更深的翻
            guard !candidates.isEmpty else { return }
            candidateIndex = WindowPickSupport.steppedCandidateIndex(
                current: candidateIndex, count: candidates.count,
                scrollUp: event.scrollingDeltaY > 0)
            redrawHighlight()
        case .leftMouseDown:
            // 光标下没有可截窗口（桌面）＝这次选择落空，按取消处理：
            // 与旧行为「窗口截不到就提示音」相比，显式退出更可预期。
            finish(candidates.isEmpty ? nil : candidates[min(candidateIndex ?? 0,
                                                             candidates.count - 1)].id)
        case .rightMouseDown:
            finish(nil)
        case .keyDown:
            if event.keyCode == 53 { finish(nil) }   // Escape
        default:
            break
        }
    }

    private func refreshHighlight(force: Bool) {
        let location = NSEvent.mouseLocation
        if !force, abs(location.x - lastTestPoint.x) < 2, abs(location.y - lastTestPoint.y) < 2 {
            return
        }
        lastTestPoint = location

        // 光标换屏时跟随 key：mouseMoved 只派发给 key window，换 key 之后
        // 下一帧移动事件才继续到达（ Esc 也始终有人接）。
        if let keyLayer = layers.first(where: { $0.window.frame.contains(location) }),
           !keyLayer.window.isKeyWindow {
            keyLayer.window.makeKey()
        }

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            candidates = []
            candidateIndex = nil
            redrawHighlight()
            return
        }
        candidates = WindowPickSupport.candidates(
            from: list,
            at: location,
            primaryScreenHeight: ScreenCapture.primaryScreenHeight,
            ownPID: ProcessInfo.processInfo.processIdentifier)
        candidateIndex = candidates.isEmpty ? nil : 0
        redrawHighlight()
    }

    /// 把当前候选的 frame 派发给每块屏的视图（窗口跨界时各画与自己相交的部分，
    /// 视图裁剪自动处理越界）。
    private func redrawHighlight() {
        let current: WindowPickSupport.Candidate? = candidates.isEmpty
            ? nil
            : candidates[min(candidateIndex ?? 0, candidates.count - 1)]
        for layer in layers {
            if let current {
                // 全局 AppKit 坐标 → 该屏视图坐标（视图原点 = 屏原点，副屏原点可为负）
                layer.view.highlightFrame = current.frame.offsetBy(
                    dx: -layer.view.screenFrame.minX, dy: -layer.view.screenFrame.minY)
                layer.view.highlightTitle = current.title
            } else {
                layer.view.highlightFrame = nil
                layer.view.highlightTitle = nil
            }
            layer.view.needsDisplay = true
        }
    }

    private func finish(_ windowID: CGWindowID?) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        for layer in layers {
            layer.window.orderOut(nil)
        }
        completionHandler(windowID)
    }
}

/// 单块屏的选择覆盖层视图：压暗 + 高亮挖洞 + 边框 + 标题 HUD + 底部操作提示。
final class WindowPickView: NSView {
    /// 本屏的全局 frame（highlightFrame 的换算基准；init 时冻结，别用时再取）。
    var screenFrame: CGRect = .zero
    /// 高亮矩形，**视图坐标**（协调器已扣掉屏原点）。
    var highlightFrame: CGRect?
    var highlightTitle: String?

    private let dimAlpha: CGFloat = 0.35

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 整体压暗
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        ctx.fill(bounds)

        // 2. 高亮区挖洞：clear 混合把「压暗层 + 窗口自身绘制」一并擦成透明，
        //    露出覆盖层后面**活着的**屏幕 —— 选择模式不冻结（理由见协调器文档）。
        guard let highlight = highlightFrame else {
            drawHint(ctx: ctx)
            return
        }
        ctx.setBlendMode(.clear)
        ctx.fill(highlight)
        ctx.setBlendMode(.normal)

        // 3. 边框（ accent 色在深浅桌面下都够醒目）
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(highlight.insetBy(dx: -1, dy: -1))

        drawTitleHUD(ctx: ctx, for: highlight)
        drawHint(ctx: ctx)
    }

    /// 窗口标题牌：贴在高亮区左上角内侧；窗口太矮放不下时改贴外侧下方。
    private func drawTitleHUD(ctx: CGContext, for highlight: CGRect) {
        let text = (highlightTitle?.isEmpty ?? true) ? "未命名窗口" : highlightTitle!
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let paddingH: CGFloat = 8, paddingV: CGFloat = 5
        let box = NSSize(width: size.width + paddingH * 2, height: size.height + paddingV * 2)

        var origin = NSPoint(x: highlight.minX + 4, y: highlight.maxY - box.height - 4)
        if origin.y < bounds.minY {
            origin.y = highlight.minY + 4
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.maxX - box.width, bounds.minX))

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.fill(NSRect(origin: origin, size: box))
        (text as NSString).draw(
            at: NSPoint(x: origin.x + paddingH, y: origin.y + paddingV),
            withAttributes: attributes
        )
    }

    /// 底部居中的操作提示。选择模式是新交互，第一次遇到必须教一句怎么用。
    private func drawHint(ctx: CGContext) {
        let text = "单击截取　·　滚轮换选重叠窗口　·　Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let paddingH: CGFloat = 10, paddingV: CGFloat = 6
        let box = NSSize(width: size.width + paddingH * 2, height: size.height + paddingV * 2)
        let origin = NSPoint(x: bounds.midX - box.width / 2,
                             y: bounds.minY + 24)

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.fill(NSRect(origin: origin, size: box))
        (text as NSString).draw(
            at: NSPoint(x: origin.x + paddingH, y: origin.y + paddingV),
            withAttributes: attributes
        )
    }
}
