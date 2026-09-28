import Cocoa

/// 延迟截图的倒计时浮窗：每块屏一个居中大数字徽章，**点击徽章即取消**。
///
/// 刻意**不激活应用、不抢焦点**：倒计时是给用户时间把画面排好的，
/// 弹窗抢焦点反而打断用户正在做的窗口切换。也因此取消交互用「点徽章」
/// 而不是 Esc —— 不激活就拿不到键盘事件。
///
/// 每 1 秒步进一次；走完调 `onEnd`（由调用方发起真正的截图流程），
/// 被点掉调 `onCancel`（只清引用，不发截图）。
final class CountdownHUD: NSObject {
    private final class BadgeView: NSView {
        var seconds: Int = 0 { didSet { needsDisplay = true } }
        var onTap: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onTap?()
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let circle = bounds.insetBy(dx: 6, dy: 6)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillEllipse(in: circle)
            let text = "\(seconds)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 38, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2),
                      withAttributes: attributes)
        }
    }

    private var badges: [(window: NSWindow, view: BadgeView)] = []
    private var timer: Timer?
    private var remaining: Int
    /// 是否已收场（onEnd / onCancel / cancel 都会置位；Timer 的最后一次
    /// 触发与用户点击可能同帧竞速，保证回调只发一次）
    private var finished = false
    private let onEnd: () -> Void
    private let onCancel: () -> Void

    init(seconds: Int, onEnd: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.remaining = max(1, seconds)
        self.onEnd = onEnd
        self.onCancel = onCancel
        super.init()
    }

    func begin() {
        let badgeSize: CGFloat = 88
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: badgeSize, height: badgeSize),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // 高于覆盖层（.statusBar + 1）：倒计时期间用户可能已经能看到
            // 覆盖层外的世界，但此刻只有徽章自己，压住一切即可
            window.level = .statusBar + 3
            window.ignoresMouseEvents = false

            let view = BadgeView(frame: NSRect(origin: .zero,
                                               size: NSSize(width: badgeSize, height: badgeSize)))
            view.seconds = remaining
            view.onTap = { [weak self] in self?.finish(cancelled: true) }
            window.contentView = view
            window.setFrameTopLeftPoint(
                NSPoint(x: screen.frame.midX + badgeSize / 2,
                        y: screen.frame.maxY - 120))
            window.orderFront(nil)
            badges.append((window, view))
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// 外部主动取消（例如用户又点了一次立即截图）。
    func cancel() {
        finish(cancelled: true)
    }

    private func tick() {
        remaining -= 1
        guard remaining > 0 else {
            finish(cancelled: false)
            return
        }
        for badge in badges {
            badge.view.seconds = remaining
        }
    }

    private func finish(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        for badge in badges {
            badge.window.orderOut(nil)
        }
        badges.removeAll()
        if cancelled {
            onCancel()
        } else {
            onEnd()
        }
    }
}
