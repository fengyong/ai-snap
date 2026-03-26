import Cocoa

/// 标注画布 — 实现双图层 Color Picking 方案
class AnnotationView: NSView {
    // Layer O: 原始截图
    private let baseImage: NSImage
    // Map<唯一颜色Key, Arrow>
    private var arrows: [UInt32: Arrow] = [:]
    // Layer B: 隐藏的 hit test 缓冲区
    private var hitTestBuffer: HitTestBuffer

    private var state: CanvasState = .idle
    private var currentDrawEnd: CGPoint?

    // 当前箭头颜色（用户可见的颜色）
    var arrowColor: NSColor = .red
    var arrowLineWidth: CGFloat = 3.0

    // 当前被选中的箭头 key (高亮显示用)
    private var selectedKey: UInt32?

    init(image: NSImage) {
        self.baseImage = image
        let size = image.size
        self.hitTestBuffer = HitTestBuffer(size: size)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Mouse Events

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 在 Layer B 上查找鼠标位置的颜色
        let colorKey = hitTestBuffer.pickColorKey(at: point)

        if colorKey != 0, let arrow = arrows[colorKey] {
            // 命中已有箭头 → 进入移动模式
            let center = CGPoint(
                x: (arrow.startPoint.x + arrow.endPoint.x) / 2,
                y: (arrow.startPoint.y + arrow.endPoint.y) / 2
            )
            let offset = CGVector(dx: point.x - center.x, dy: point.y - center.y)
            state = .moving(colorKey: colorKey, grabOffset: offset)
            selectedKey = colorKey
        } else {
            // 未命中 → 开始画新箭头
            state = .drawing(start: point)
            selectedKey = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch state {
        case .moving(let colorKey, let grabOffset):
            guard var arrow = arrows[colorKey] else { return }

            let oldCenter = CGPoint(
                x: (arrow.startPoint.x + arrow.endPoint.x) / 2,
                y: (arrow.startPoint.y + arrow.endPoint.y) / 2
            )
            let newCenter = CGPoint(
                x: point.x - grabOffset.dx,
                y: point.y - grabOffset.dy
            )
            let delta = CGVector(
                dx: newCenter.x - oldCenter.x,
                dy: newCenter.y - oldCenter.y
            )

            arrow.startPoint.x += delta.dx
            arrow.startPoint.y += delta.dy
            arrow.endPoint.x += delta.dx
            arrow.endPoint.y += delta.dy
            arrows[colorKey] = arrow

            // 重绘 Layer B
            hitTestBuffer.redrawAll(arrows: arrows)
            needsDisplay = true

        case .drawing:
            currentDrawEnd = point
            needsDisplay = true

        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch state {
        case .drawing(let start):
            // 最小长度检查，避免点击产生零长度箭头
            let dist = hypot(point.x - start.x, point.y - start.y)
            if dist > 5 {
                let colorKey = hitTestBuffer.generateUniqueColorKey()
                let arrow = Arrow(
                    startPoint: start,
                    endPoint: point,
                    color: arrowColor,
                    lineWidth: arrowLineWidth,
                    hitTestColorKey: colorKey
                )
                arrows[colorKey] = arrow

                // 在 Layer B 上绘制新箭头
                hitTestBuffer.drawArrow(arrow)
            }
            currentDrawEnd = nil

        case .moving:
            break  // 位置已在 drag 中更新

        case .idle:
            break
        }

        state = .idle
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
            if let key = selectedKey {
                arrows.removeValue(forKey: key)
                selectedKey = nil
                hitTestBuffer.redrawAll(arrows: arrows)
                needsDisplay = true
            }
        }
    }

    // MARK: - Drawing (Layer A)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 绘制底图 (Layer O)
        let imageRect = CGRect(origin: .zero, size: baseImage.size)
        baseImage.draw(in: imageRect)

        // 2. 绘制所有已存在的箭头 (用户颜色)
        for (key, arrow) in arrows {
            arrow.draw(in: ctx)

            // 选中状态：画端点手柄
            if key == selectedKey {
                drawSelectionHandles(arrow: arrow, in: ctx)
            }
        }

        // 3. 绘制正在画的箭头 (预览)
        if case .drawing(let start) = state, let end = currentDrawEnd {
            let previewArrow = Arrow(
                startPoint: start,
                endPoint: end,
                color: arrowColor,
                lineWidth: arrowLineWidth,
                hitTestColorKey: 0
            )
            previewArrow.draw(in: ctx)
        }
    }

    private func drawSelectionHandles(arrow: Arrow, in ctx: CGContext) {
        let handleSize: CGFloat = 6
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)

        for point in [arrow.startPoint, arrow.endPoint] {
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            ctx.fillEllipse(in: handleRect)
            ctx.strokeEllipse(in: handleRect)
        }
    }

    // MARK: - Export

    /// 生成最终合成图片（底图 + 所有箭头）
    func compositeImage() -> NSImage {
        let size = baseImage.size
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let rect = CGRect(origin: .zero, size: size)
            baseImage.draw(in: rect)
            for (_, arrow) in arrows {
                arrow.draw(in: ctx)
            }
        }
        image.unlockFocus()
        return image
    }
}
