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

    // 水印配置
    var watermarkConfig = WatermarkConfig()

    // 当前被选中的对象 key
    private(set) var selectedKey: UInt32?

    // 点捕捉：当前活跃的吸附点（用于可视化）
    private var activeSnapPoint: CGPoint?
    private let snapThreshold: CGFloat = 12.0

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
        let flags = event.modifierFlags

        // 已选中对象时，修饰键触发旋转/缩放
        if let key = selectedKey, let obj = objects[key] {
            if flags.contains(.option) {
                // Option+拖拽 → 旋转
                let angle = atan2(point.y - obj.center.y, point.x - obj.center.x)
                state = .rotating(colorKey: key, lastAngle: angle)
                needsDisplay = true
                return
            }
            if flags.contains(.shift) {
                // Shift+拖拽 → 缩放
                let dist = hypot(point.x - obj.center.x, point.y - obj.center.y)
                if dist > 1 {
                    state = .scaling(colorKey: key, lastDistance: dist)
                }
                needsDisplay = true
                return
            }
        }

        // 在 Layer B 上查找鼠标位置的颜色
        let colorKey = hitTestBuffer.pickColorKey(at: point)

        if colorKey != 0, let obj = objects[colorKey] {
            // 命中已有对象 → 进入移动模式
            let offset = CGVector(dx: point.x - obj.center.x,
                                  dy: point.y - obj.center.y)
            state = .moving(colorKey: colorKey, grabOffset: offset)
            selectedKey = colorKey
        } else if case .stamp(let stampType) = currentTool {
            // Stamp 工具：单击直接放置
            let key = hitTestBuffer.generateUniqueColorKey()
            let stamp = StampObject(center: point, size: 32, stampType: stampType,
                                    color: currentColor, hitTestColorKey: key)
            objects[key] = stamp
            zOrder.append(key)
            hitTestBuffer.drawObject(stamp)
            refreshDebugView()
            selectedKey = key
            state = .idle
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

            // 如果移动的是箭头，解除附着
            if let arrow = obj as? Arrow {
                arrow.startAttachment = nil
                arrow.endAttachment = nil
            }
            // 如果移动的是形状，更新附着的箭头端点
            updateAttachedArrows(forParent: colorKey)

            // 重绘 Layer B
            hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
            refreshDebugView()
            needsDisplay = true

        case .rotating(let colorKey, let lastAngle):
            guard let obj = objects[colorKey] else { return }
            let currentAngle = atan2(point.y - obj.center.y, point.x - obj.center.x)
            let deltaAngle = currentAngle - lastAngle
            obj.rotate(by: deltaAngle)
            state = .rotating(colorKey: colorKey, lastAngle: currentAngle)

            hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
            refreshDebugView()
            needsDisplay = true

        case .scaling(let colorKey, let lastDistance):
            guard let obj = objects[colorKey] else { return }
            let currentDist = hypot(point.x - obj.center.x, point.y - obj.center.y)
            if currentDist > 1 && lastDistance > 1 {
                let factor = currentDist / lastDistance
                let box = obj.boundingBox
                let minDim = min(box.width, box.height)
                if minDim * factor >= 5 || factor >= 1 {
                    obj.scale(by: factor)
                    state = .scaling(colorKey: colorKey, lastDistance: currentDist)
                }
            }

            hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
            refreshDebugView()
            needsDisplay = true

        case .drawing:
            currentDrawEnd = applySnap(to: point, excludeKey: nil)
            needsDisplay = true

        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch state {
        case .drawing(let tool, let start):
            // 对终点应用吸附
            let snappedEnd = applySnap(to: point, excludeKey: nil)
            // 最小长度检查
            let dist = hypot(snappedEnd.x - start.x, snappedEnd.y - start.y)
            if dist > 5 {
                let colorKey = hitTestBuffer.generateUniqueColorKey()
                let obj: any AnnotationObject

                switch tool {
                case .arrow:
                    let arrow = Arrow(startPoint: start, endPoint: snappedEnd,
                                color: currentColor, lineWidth: currentLineWidth,
                                hitTestColorKey: colorKey, style: currentArrowStyle)
                    arrow.startAttachment = detectAttachment(at: start, excludeKey: colorKey)
                    arrow.endAttachment = detectAttachment(at: snappedEnd, excludeKey: colorKey)
                    if let att = arrow.startAttachment, let pos = resolveAttachmentPosition(att) {
                        arrow.startPoint = pos
                    }
                    if let att = arrow.endAttachment, let pos = resolveAttachmentPosition(att) {
                        arrow.endPoint = pos
                    }
                    obj = arrow

                case .rectangle:
                    obj = RectangleShape(from: start, to: snappedEnd,
                                         color: currentColor,
                                         lineWidth: currentLineWidth,
                                         hitTestColorKey: colorKey)

                case .circle:
                    let centerPt = CGPoint(x: (start.x + snappedEnd.x) / 2,
                                           y: (start.y + snappedEnd.y) / 2)
                    let radius = dist / 2
                    obj = CircleShape(center: centerPt, radius: radius,
                                      color: currentColor,
                                      lineWidth: currentLineWidth,
                                      hitTestColorKey: colorKey)

                case .stamp:
                    // stamp 在 mouseDown 中直接放置，不会走到这里
                    currentDrawEnd = nil
                    state = .idle
                    needsDisplay = true
                    return

                case .spotlight:
                    obj = SpotlightShape(from: start, to: snappedEnd,
                                         hitTestColorKey: colorKey)
                }

                objects[colorKey] = obj
                zOrder.append(colorKey)

                // 在 Layer B 上绘制新对象
                hitTestBuffer.drawObject(obj)
                refreshDebugView()
            }
            currentDrawEnd = nil

        case .moving:
            break

        case .rotating, .scaling:
            break

        case .idle:
            break
        }

        state = .idle
        activeSnapPoint = nil
        needsDisplay = true
    }    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
            if let key = selectedKey {
                // 级联删除附着的子箭头
                cascadeDelete(parentKey: key)
                objects.removeValue(forKey: key)
                zOrder.removeAll { $0 == key }
                selectedKey = nil
                hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
                refreshDebugView()
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

        // 2. 绘制 Spotlight 遮罩（半透明遮盖 + 挖空高亮区域）
        drawSpotlightOverlay(in: ctx)

        // 3. 按 Z 序绘制所有对象
        for key in zOrder {
            guard let obj = objects[key] else { continue }
            obj.draw(in: ctx)

            // 选中状态：画端点手柄
            if key == selectedKey {
                drawSelectionHandles(for: obj, in: ctx)
            }
        }

        // 4. 绘制正在画的图形预览
        if case .drawing(let tool, let start) = state, let end = currentDrawEnd {
            drawPreview(tool: tool, start: start, end: end, in: ctx)
        }

        // 5. 绘制吸附指示器
        if let snapPt = activeSnapPoint {
            drawSnapIndicator(at: snapPt, in: ctx)
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

        case .stamp:
            break  // stamp 是单击放置，不需要拖拽预览

        case .spotlight:
            let imageRect = CGRect(origin: .zero, size: baseImage.size)
            ctx.saveGState()
            let spotRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
            let spotPath = CGPath(roundedRect: spotRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            let fullPath = CGMutablePath()
            fullPath.addRect(imageRect)
            fullPath.addPath(spotPath)
            ctx.addPath(fullPath)
            ctx.clip(using: .evenOdd)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.fill(imageRect)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.addPath(spotPath)
            ctx.strokePath()
        }
    }

    // MARK: - Object Snap

    /// 查找距离 cursor 最近的吸附点（排除指定对象自身）
    private func findNearestSnapPoint(to cursor: CGPoint, excludeKey: UInt32?) -> SnapPoint? {
        var bestDist: CGFloat = snapThreshold
        var bestSnap: SnapPoint?

        for (key, obj) in objects {
            if key == excludeKey { continue }
            for snap in obj.snapPoints() {
                let dist = hypot(cursor.x - snap.point.x, cursor.y - snap.point.y)
                if dist < bestDist {
                    bestDist = dist
                    bestSnap = snap
                }
            }
        }
        return bestSnap
    }

    /// 对一个点应用吸附，返回吸附后的点
    private func applySnap(to point: CGPoint, excludeKey: UInt32?) -> CGPoint {
        if let snap = findNearestSnapPoint(to: point, excludeKey: excludeKey) {
            activeSnapPoint = snap.point
            return snap.point
        }
        activeSnapPoint = nil
        return point
    }

    /// 绘制吸附指示器
    private func drawSnapIndicator(at point: CGPoint, in ctx: CGContext) {
        let size: CGFloat = 8
        ctx.setStrokeColor(NSColor.systemCyan.cgColor)
        ctx.setLineWidth(1.5)

        // 十字线
        ctx.move(to: CGPoint(x: point.x - size, y: point.y))
        ctx.addLine(to: CGPoint(x: point.x + size, y: point.y))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: point.x, y: point.y - size))
        ctx.addLine(to: CGPoint(x: point.x, y: point.y + size))
        ctx.strokePath()

        // 菱形
        ctx.move(to: CGPoint(x: point.x, y: point.y - size * 0.6))
        ctx.addLine(to: CGPoint(x: point.x + size * 0.6, y: point.y))
        ctx.addLine(to: CGPoint(x: point.x, y: point.y + size * 0.6))
        ctx.addLine(to: CGPoint(x: point.x - size * 0.6, y: point.y))
        ctx.closePath()
        ctx.strokePath()
    }

    /// 绘制 Spotlight 遮罩：全图半透明遮盖，挖空所有 SpotlightShape 区域
    private func drawSpotlightOverlay(in ctx: CGContext) {
        // 收集所有 Spotlight 对象
        var spotlights: [SpotlightShape] = []
        for key in zOrder {
            if let spot = objects[key] as? SpotlightShape {
                spotlights.append(spot)
            }
        }
        guard !spotlights.isEmpty else { return }

        let imageRect = CGRect(origin: .zero, size: baseImage.size)
        ctx.saveGState()

        // 构造路径：全图矩形 + 所有 Spotlight 高亮区域（even-odd 挖空）
        let fullPath = CGMutablePath()
        fullPath.addRect(imageRect)
        for spot in spotlights {
            var transform = CGAffineTransform.identity
                .translatedBy(x: spot.center.x, y: spot.center.y)
                .rotated(by: spot.rotation)
            let localRect = CGRect(x: -spot.width / 2, y: -spot.height / 2,
                                   width: spot.width, height: spot.height)
            let roundedPath = CGPath(roundedRect: localRect,
                                     cornerWidth: spot.cornerRadius,
                                     cornerHeight: spot.cornerRadius,
                                     transform: &transform)
            fullPath.addPath(roundedPath)
        }

        ctx.addPath(fullPath)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(imageRect)
        ctx.restoreGState()
    }

    // MARK: - Object Attachment

    private let attachThreshold: CGFloat = 15.0

    /// 检测一个点附近是否有可附着的形状，返回 Attachment 或 nil
    private func detectAttachment(at point: CGPoint, excludeKey: UInt32?) -> Attachment? {
        var bestDist: CGFloat = attachThreshold
        var bestAttachment: Attachment?

        for (key, obj) in objects {
            if key == excludeKey { continue }
            // 箭头不作为父对象
            if obj is Arrow { continue }

            // 先检查 snap points
            for (index, snap) in obj.snapPoints().enumerated() {
                let dist = hypot(point.x - snap.point.x, point.y - snap.point.y)
                if dist < bestDist {
                    bestDist = dist
                    bestAttachment = Attachment(parentKey: key, anchorType: .snapPoint(index: index))
                }
            }

            // 检查周长最近点
            let nearest = obj.nearestPerimeterPoint(to: point)
            let dist = hypot(point.x - nearest.x, point.y - nearest.y)
            if dist < bestDist {
                bestDist = dist
                // 计算周长参数
                let param = computePerimeterParameter(for: obj, at: nearest)
                bestAttachment = Attachment(parentKey: key, anchorType: .perimeter(parameter: param))
            }
        }
        return bestAttachment
    }

    /// 计算点在对象周长上的参数 (0...1)
    private func computePerimeterParameter(for obj: any AnnotationObject, at point: CGPoint) -> CGFloat {
        if let circle = obj as? CircleShape {
            let dx = point.x - circle.center.x
            let dy = point.y - circle.center.y
            var angle = atan2(dy, dx) - circle.rotation
            if angle < 0 { angle += 2 * .pi }
            return angle / (2 * .pi)
        }
        if let rect = obj as? RectangleShape {
            // 转换到局部坐标
            let local = rotatePoint(point, around: rect.center, by: -rect.rotation)
            let lx = local.x - rect.center.x
            let ly = local.y - rect.center.y
            let hw = rect.width / 2, hh = rect.height / 2
            let perimeter = 2 * (rect.width + rect.height)
            // 沿周长测量距离
            var d: CGFloat = 0
            if ly <= -hh + 0.1 { d = lx + hw }                                  // bottom
            else if lx >= hw - 0.1 { d = rect.width + (ly + hh) }               // right
            else if ly >= hh - 0.1 { d = rect.width + rect.height + (hw - lx) } // top
            else { d = 2 * rect.width + rect.height + (hh - ly) }               // left
            return max(0, min(1, d / perimeter))
        }
        if let stamp = obj as? StampObject {
            let local = rotatePoint(point, around: stamp.center, by: -stamp.rotation)
            let lx = local.x - stamp.center.x
            let ly = local.y - stamp.center.y
            let half = stamp.size / 2
            let perimeter = stamp.size * 4
            var d: CGFloat = 0
            if ly <= -half + 0.1 { d = lx + half }
            else if lx >= half - 0.1 { d = stamp.size + (ly + half) }
            else if ly >= half - 0.1 { d = 2 * stamp.size + (half - lx) }
            else { d = 3 * stamp.size + (half - ly) }
            return max(0, min(1, d / perimeter))
        }
        return 0
    }

    /// 解析附着点的当前世界坐标
    private func resolveAttachmentPosition(_ attachment: Attachment) -> CGPoint? {
        guard let parent = objects[attachment.parentKey] else { return nil }

        switch attachment.anchorType {
        case .snapPoint(let index):
            let snaps = parent.snapPoints()
            guard index < snaps.count else { return nil }
            return snaps[index].point

        case .perimeter(let parameter):
            if let circle = parent as? CircleShape {
                return circle.pointOnPerimeter(at: parameter)
            }
            if let rect = parent as? RectangleShape {
                return rect.pointOnPerimeter(at: parameter)
            }
            if let stamp = parent as? StampObject {
                return stamp.pointOnPerimeter(at: parameter)
            }
            return nil
        }
    }

    /// 更新所有附着到指定父对象的箭头端点
    private func updateAttachedArrows(forParent parentKey: UInt32) {
        for (_, obj) in objects {
            guard let arrow = obj as? Arrow else { continue }
            if let att = arrow.startAttachment, att.parentKey == parentKey {
                if let pos = resolveAttachmentPosition(att) {
                    arrow.startPoint = pos
                }
            }
            if let att = arrow.endAttachment, att.parentKey == parentKey {
                if let pos = resolveAttachmentPosition(att) {
                    arrow.endPoint = pos
                }
            }
        }
    }

    /// 级联删除：删除所有附着到指定父对象的箭头
    private func cascadeDelete(parentKey: UInt32) {
        var toDelete: [UInt32] = []
        for (key, obj) in objects {
            guard let arrow = obj as? Arrow else { continue }
            if (arrow.startAttachment?.parentKey == parentKey) ||
               (arrow.endAttachment?.parentKey == parentKey) {
                toDelete.append(key)
            }
        }
        for key in toDelete {
            objects.removeValue(forKey: key)
            zOrder.removeAll { $0 == key }
        }
    }

    // MARK: - Debug Visualization

    /// 刷新右侧的 Layer B 调试面板
    private func refreshDebugView() {
        guard let imageView = debugImageView else { return }
        let debugImage = hitTestBuffer.debugVisualization(objects: objects, zOrder: zOrder)
        imageView.image = debugImage
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
            // Spotlight 遮罩
            drawSpotlightOverlay(in: ctx)
            for key in zOrder {
                if let obj = objects[key] {
                    obj.draw(in: ctx)
                }
            }
            // 水印（最后绘制，覆盖在所有内容之上）
            if watermarkConfig.enabled && !watermarkConfig.text.isEmpty {
                drawWatermark(in: ctx, size: size)
            }
        }
        image.unlockFocus()
        return image
    }

    /// 绘制水印
    private func drawWatermark(in ctx: CGContext, size: NSSize) {
        let config = watermarkConfig
        let font = NSFont.systemFont(ofSize: config.fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: config.color,
        ]
        let nsText = config.text as NSString
        let textSize = nsText.size(withAttributes: attrs)

        if config.tiled {
            // 平铺水印
            ctx.saveGState()
            let diagonal = hypot(size.width, size.height)
            let spacing = config.tileSpacing
            // 从中心旋转绘制平铺网格
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: config.angle)
            let halfD = diagonal / 2 + spacing
            var y = -halfD
            while y < halfD {
                var x = -halfD
                while x < halfD {
                    nsText.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
                    x += textSize.width + spacing
                }
                y += textSize.height + spacing
            }
            ctx.restoreGState()
        } else {
            // 右下角单个水印
            let margin: CGFloat = 12
            let drawPoint = CGPoint(x: size.width - textSize.width - margin,
                                    y: margin)
            nsText.draw(at: drawPoint, withAttributes: attrs)
        }
    }
}
