import Cocoa

/// 标注画布 — 支持多形状类型的双图层 Color Picking 方案
class AnnotationView: NSView {
    // Layer O: 原始截图
    private let baseImage: NSImage
    // Map<唯一颜色Key, AnnotationObject>
    private var objects: [UInt32: any AnnotationObject] = [:]
    // Z 序：从底到顶的 colorKey 数组
    private var zOrder: [UInt32] = []
    // Layer B: 隐藏的 hit test 缓冲区
    private var hitTestBuffer: HitTestBuffer

    private var state: CanvasState = .idle
    private var currentDrawEnd: CGPoint?

    // 当前工具和样式
    var currentTool: DrawingTool = .arrow
    var currentColor: NSColor = .red
    var currentLineWidth: CGFloat = 3.0
    var currentArrowStyle: ArrowStyle = .default

    // 当前被选中的对象 key
    private(set) var selectedKey: UInt32?

    // 调试面板：外部挂载的 NSImageView，用于实时显示 Layer B 可视化
    weak var debugImageView: NSImageView?

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

        if colorKey != 0, let obj = objects[colorKey] {
            // 命中已有对象 → 进入移动模式
            let offset = CGVector(dx: point.x - obj.center.x,
                                  dy: point.y - obj.center.y)
            state = .moving(colorKey: colorKey, grabOffset: offset)
            selectedKey = colorKey
        } else {
            // 未命中 → 开始画新图形
            state = .drawing(tool: currentTool, start: point)
            selectedKey = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch state {
        case .moving(let colorKey, let grabOffset):
            guard let obj = objects[colorKey] else { return }

            let oldCenter = obj.center
            let newCenter = CGPoint(
                x: point.x - grabOffset.dx,
                y: point.y - grabOffset.dy
            )
            let delta = CGVector(
                dx: newCenter.x - oldCenter.x,
                dy: newCenter.y - oldCenter.y
            )

            obj.move(by: delta)

            // 重绘 Layer B
            hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
            refreshDebugView()
            needsDisplay = true
            currentDrawEnd = point
            needsDisplay = true

        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch state {
        case .drawing(let tool, let start):
            // 最小长度检查
            let dist = hypot(point.x - start.x, point.y - start.y)
            if dist > 5 {
                let colorKey = hitTestBuffer.generateUniqueColorKey()
                let obj: any AnnotationObject

                switch tool {
                case .arrow:
                    obj = Arrow(startPoint: start, endPoint: point,
                                color: currentColor, lineWidth: currentLineWidth,
                                hitTestColorKey: colorKey, style: currentArrowStyle)

                case .rectangle:
                    obj = RectangleShape(from: start, to: point,
                                         color: currentColor,
                                         lineWidth: currentLineWidth,
                                         hitTestColorKey: colorKey)

                case .circle:
                    let centerPt = CGPoint(x: (start.x + point.x) / 2,
                                           y: (start.y + point.y) / 2)
                    let radius = dist / 2
                    obj = CircleShape(center: centerPt, radius: radius,
                                      color: currentColor,
                                      lineWidth: currentLineWidth,
                                      hitTestColorKey: colorKey)
                }

                objects[colorKey] = obj
                zOrder.append(colorKey)

                // 在 Layer B 上绘制新对象
                hitTestBuffer.drawObject(obj)
            }
            currentDrawEnd = nil

        case .moving:
            break

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
                objects.removeValue(forKey: key)
                zOrder.removeAll { $0 == key }
                selectedKey = nil
                hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
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

        // 2. 按 Z 序绘制所有对象
        for key in zOrder {
            guard let obj = objects[key] else { continue }
            obj.draw(in: ctx)

            // 选中状态：画端点手柄
            if key == selectedKey {
                drawSelectionHandles(for: obj, in: ctx)
            }
        }

        // 3. 绘制正在画的图形预览
        if case .drawing(let tool, let start) = state, let end = currentDrawEnd {
            drawPreview(tool: tool, start: start, end: end, in: ctx)
        }
    }

    private func drawSelectionHandles(for obj: any AnnotationObject, in ctx: CGContext) {
        let handleSize: CGFloat = 6
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)

        for point in obj.selectionHandlePoints() {
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

    private func drawPreview(tool: DrawingTool, start: CGPoint, end: CGPoint, in ctx: CGContext) {
        switch tool {
        case .arrow:
            let preview = Arrow(startPoint: start, endPoint: end,
                                color: currentColor, lineWidth: currentLineWidth,
                                hitTestColorKey: 0, style: currentArrowStyle)
            preview.draw(in: ctx)

        case .rectangle:
            let preview = RectangleShape(from: start, to: end,
                                          color: currentColor,
                                          lineWidth: currentLineWidth,
                                          hitTestColorKey: 0)
            preview.draw(in: ctx)

        case .circle:
            let centerPt = CGPoint(x: (start.x + end.x) / 2,
                                   y: (start.y + end.y) / 2)
            let radius = hypot(end.x - start.x, end.y - start.y) / 2
            let preview = CircleShape(center: centerPt, radius: radius,
                                       color: currentColor,
                                       lineWidth: currentLineWidth,
                                       hitTestColorKey: 0)
            preview.draw(in: ctx)
        }
    }

    // MARK: - Export

    /// 生成最终合成图片（底图 + 所有标注对象）
    func compositeImage() -> NSImage {
        let size = baseImage.size
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let rect = CGRect(origin: .zero, size: size)
            baseImage.draw(in: rect)
            for key in zOrder {
                if let obj = objects[key] {
                    obj.draw(in: ctx)
                }
            }
        }
        image.unlockFocus()
        return image
    }
}
