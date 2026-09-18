import Cocoa

/// 标注画布 — 支持多形状类型的双图层 Color Picking 方案
class AnnotationView: NSView {
    // Layer O: 原始截图
    private let baseImage: NSImage
    /// 源截图的像素尺寸（由 AppDelegate 传入，用于固定导出分辨率）
    private let sourcePixelSize: CGSize?
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
    var currentLineWidth: CGFloat = 15.0
    var currentArrowStyle: ArrowStyle = .default

    // 水印配置
    var watermarkConfig = WatermarkConfig()

    // 当前被选中的对象 key（变化时通知外部，便于工具栏同步高亮）
    private(set) var selectedKey: UInt32? {
        didSet { if selectedKey != oldValue { onSelectionChanged?() } }
    }

    /// 选中对象发生变化时回调（用于把调色板/线宽控件同步成该对象的样式）
    var onSelectionChanged: (() -> Void)?

    /// 当前选中对象的颜色（无选中时为 nil）
    var selectedObjectColor: NSColor? {
        guard let key = selectedKey, let obj = objects[key] else { return nil }
        return obj.color
    }

    /// 当前选中对象的线宽（不支持线宽的对象返回 nil）
    var selectedObjectLineWidth: CGFloat? {
        guard let key = selectedKey, let obj = objects[key] else { return nil }
        return AnnotationView.lineWidth(of: obj)
    }

    private static func lineWidth(of obj: any AnnotationObject) -> CGFloat? {
        if let a = obj as? Arrow { return a.lineWidth }
        if let r = obj as? RectangleShape { return r.lineWidth }
        if let c = obj as? CircleShape { return c.lineWidth }
        return nil
    }

    private static func setLineWidth(_ value: CGFloat, on obj: any AnnotationObject) {
        if let a = obj as? Arrow { a.lineWidth = value }
        else if let r = obj as? RectangleShape { r.lineWidth = value }
        else if let c = obj as? CircleShape { c.lineWidth = value }
    }

    /// 把选中对象的样式改成给定值（可撤销）。返回是否真的发生了变化。
    @discardableResult
    func restyleSelection(color newColor: NSColor? = nil, lineWidth newLineWidth: CGFloat? = nil) -> Bool {
        guard let key = selectedKey, let obj = objects[key] else { return false }

        let oldColor = obj.color
        let oldLineWidth = AnnotationView.lineWidth(of: obj)

        var changed = false
        if let c = newColor, !colorsEqual(c, obj.color) {
            obj.color = c
            changed = true
        }
        if let w = newLineWidth, let current = oldLineWidth, abs(current - w) > 0.01 {
            AnnotationView.setLineWidth(w, on: obj)
            changed = true
        }
        guard changed else { return false }

        undoStack.append(.restyle(colorKey: key,
                                  oldColor: oldColor, newColor: obj.color,
                                  oldLineWidth: oldLineWidth,
                                  newLineWidth: AnnotationView.lineWidth(of: obj)))
        redoStack.removeAll()
        contentDidChange()
        refreshDebugView()
        needsDisplay = true
        return true
    }

    /// 滑块拖动过程中实时改线宽，但**不记账**。
    ///
    /// 一整段拖动由 `commitSelectionLineWidth` 在松手时记成一条 undo。
    /// 旧实现每来一次连续 action 就 append 一条 `.restyle`，
    /// 拖一次滑块会产生几十条撤销记录，Cmd+Z 要按几十次才回得去。
    func previewSelectionLineWidth(_ value: CGFloat) {
        guard let key = selectedKey, let obj = objects[key],
              AnnotationView.lineWidth(of: obj) != nil else { return }
        AnnotationView.setLineWidth(value, on: obj)
        refreshDebugView()
        needsDisplay = true
    }

    /// 把一整段滑块拖动记成**一条** undo。
    /// - Parameter old: 按下滑块之前的线宽（松手时的当前值即拖动结果）
    func commitSelectionLineWidth(from old: CGFloat) {
        guard let key = selectedKey, let obj = objects[key],
              let current = AnnotationView.lineWidth(of: obj),
              abs(old - current) > 0.01 else { return }
        undoStack.append(.restyle(colorKey: key,
                                  oldColor: obj.color, newColor: obj.color,
                                  oldLineWidth: old, newLineWidth: current))
        redoStack.removeAll()
        contentDidChange()
    }

    private func colorsEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.deviceRGB), let y = b.usingColorSpace(.deviceRGB) else {
            return a == b
        }
        return abs(x.redComponent - y.redComponent) < 0.002
            && abs(x.greenComponent - y.greenComponent) < 0.002
            && abs(x.blueComponent - y.blueComponent) < 0.002
            && abs(x.alphaComponent - y.alphaComponent) < 0.002
    }

    // 点捕捉：当前活跃的吸附点（用于可视化）
    private var activeSnapPoint: CGPoint?
    private let snapThreshold: CGFloat = 12.0
    // 附着与吸附共用同一个阈值：两者不一致时，拖拽预览会停在落点、松手后却被吸走（端点"跳一下"）
    private var attachThreshold: CGFloat { snapThreshold }
    // 起始点是否吸附到了 snap point → 以该点为中心绘制
    private var drawingFromCenter: Bool = false

    // Undo/Redo 栈
    private var undoStack: [UndoAction] = []
    private var redoStack: [UndoAction] = []
    // 拖拽操作前的起始中心，用于计算总 delta
    private var dragStartCenter: CGPoint?
    // 移动箭头时会解除附着，这里记下解除前的状态供撤销使用
    private var pendingDetach: DetachedAttachments?
    private var rotateStartAngle: CGFloat = 0
    private var scaleStartFactor: CGFloat = 1

    // 调试面板：外部挂载的 NSImageView，用于实时显示 Layer B 可视化。
    // 为 nil 时 refreshDebugView() 直接返回 —— 这是"关闭调试面板"能真正省掉开销的关键。
    weak var debugImageView: NSImageView?

    /// 画布内容版本号：任何真正改变画布的操作 +1
    private var contentVersion = 0
    /// 最近一次导出时对应的内容版本（-1 = 从未导出）
    private var exportedVersion = -1

    /// 标记"画布内容变了"。所有改动画布的地方都要调一次。
    private func contentDidChange() { contentVersion += 1 }

    /// 是否还有**未导出的、且确实存在于画布上的**标注
    /// （用于关闭/重新截图前提示会丢失内容）。
    ///
    /// 语义是"有没有东西会丢"，而不是"撤销栈非不非空"：
    ///  · 画完又全部删掉 → 画布和原图一致，没有东西会丢；
    ///  · 刚导出过又没再改 → 同样没有什么可丢的。
    /// 旧的 `!undoStack.isEmpty` 在这两种情况下都会弹无谓的确认框。
    var hasEdits: Bool { !objects.isEmpty && contentVersion != exportedVersion }

    /// - Parameter pixelSize: 源图像的像素尺寸。导出时以此为准，
    ///   避免导出分辨率随"当前显示器"变化（NSImage(cgImage:size:) 的
    ///   representation 往往报不出可靠的像素尺寸）。
    init(image: NSImage, pixelSize: CGSize? = nil) {
        self.baseImage = image
        self.sourcePixelSize = pixelSize
        let size = image.size
        self.hitTestBuffer = HitTestBuffer(size: size)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Tracking Area (for passive snap on hover)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 仅在空闲状态下进行被动端点捕捉检测
        if case .idle = state {
            if let snap = findNearestSnapPoint(to: point, excludeKey: nil) {
                activeSnapPoint = snap.point
            } else {
                activeSnapPoint = nil
            }
            needsDisplay = true
        }
    }

    // MARK: - Mouse Events

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags

        // 检测是否点击了选中对象的删除叉号按钮
        if let key = selectedKey, let obj = objects[key] {
            let box = obj.boundingBox
            let padding: CGFloat = 4
            let selRect = box.insetBy(dx: -padding, dy: -padding)
            let deleteSize: CGFloat = 16
            let deleteCenter = CGPoint(x: selRect.maxX + deleteSize * 0.3,
                                        y: selRect.maxY + deleteSize * 0.3)
            let distToDelete = hypot(point.x - deleteCenter.x, point.y - deleteCenter.y)
            if distToDelete <= deleteSize / 2 + 4 {
                // 记录被删除的对象（包含级联删除的箭头）
                let zOrderBefore = zOrder
                var deletedObjects: [(UInt32, any AnnotationObject)] = []
                if let obj = objects[key] { deletedObjects.append((key, obj)) }
                // 收集级联删除的子箭头
                for (k, o) in objects {
                    if let arrow = o as? Arrow,
                       (arrow.startAttachment?.parentKey == key || arrow.endAttachment?.parentKey == key) {
                        deletedObjects.append((k, o))
                    }
                }
                undoStack.append(.delete(objects: deletedObjects, zOrderSnapshot: zOrderBefore))
                redoStack.removeAll()

                cascadeDelete(parentKey: key)
                objects.removeValue(forKey: key)
                zOrder.removeAll { $0 == key }
                selectedKey = nil
                hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
                refreshDebugView()
                needsDisplay = true
                contentDidChange()
                return
            }
        }

        // 已选中对象时，修饰键触发旋转/缩放。
        // 必须要求按下的位置落在该对象上：否则在画布空白处按 Option/Shift 拖拽会莫名其妙地
        // 改动一个远处的对象，而用户的本意是"画个新图形"。
        if let key = selectedKey, let obj = objects[key],
           obj.boundingBox.insetBy(dx: -8, dy: -8).contains(point) {
            if flags.contains(.option) {
                // Option+拖拽 → 旋转
                let angle = atan2(point.y - obj.center.y, point.x - obj.center.x)
                state = .rotating(colorKey: key, lastAngle: angle)
                rotateStartAngle = 0
                needsDisplay = true
                return
            }
            if flags.contains(.shift) {
                // Shift+拖拽 → 缩放
                let dist = hypot(point.x - obj.center.x, point.y - obj.center.y)
                if dist > 1 {
                    state = .scaling(colorKey: key, lastDistance: dist)
                    scaleStartFactor = 1
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
            dragStartCenter = obj.center
            if let arrow = obj as? Arrow {
                pendingDetach = DetachedAttachments(key: colorKey,
                                                    start: arrow.startAttachment,
                                                    end: arrow.endAttachment)
            } else {
                pendingDetach = nil
            }
        } else if case .stamp(let stampType) = currentTool {
            // Stamp 工具：单击直接放置
            let key = hitTestBuffer.generateUniqueColorKey()
            let stamp = StampObject(center: point, size: 48, stampType: stampType,
                                    color: currentColor, hitTestColorKey: key)
            objects[key] = stamp
            zOrder.append(key)
            hitTestBuffer.drawObject(stamp)
            refreshDebugView()
            undoStack.append(.add(colorKey: key))
            redoStack.removeAll()
            contentDidChange()
            selectedKey = key
            state = .idle
        } else {
            // 未命中 → 开始画新图形
            // 对起始点进行 snap：如果吸附到已有对象的 snap point，则以该点为中心绘制
            let snappedStart = applySnap(to: point, excludeKey: nil)
            drawingFromCenter = (activeSnapPoint != nil)
            state = .drawing(tool: currentTool, start: snappedStart)
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

            // 注意：**这里不解除箭头附着**。
            // 解除动作推迟到 mouseUp —— 只有确认这是一次"会被记账的真实移动"时才解。
            // 否则 2x 屏上 1 物理像素（0.5pt）的手抖就会解除附着，
            // 而 mouseUp 的记账阈值是"严格大于 0.5pt"，于是附着被清空却没有任何撤销记录。
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
            rotateStartAngle += deltaAngle
            state = .rotating(colorKey: colorKey, lastAngle: currentAngle)
            updateAttachedArrows(forParent: colorKey)      // 附着的箭头必须一起转

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
                    scaleStartFactor *= factor
                    state = .scaling(colorKey: colorKey, lastDistance: currentDist)
                    updateAttachedArrows(forParent: colorKey)   // 附着的箭头必须一起缩放
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
                    if drawingFromCenter {
                        // 以 start 为中心，拖拽确定半尺寸
                        let hw = abs(snappedEnd.x - start.x)
                        let hh = abs(snappedEnd.y - start.y)
                        obj = RectangleShape(center: start, width: max(hw * 2, 6),
                                             height: max(hh * 2, 6),
                                             color: currentColor,
                                             lineWidth: currentLineWidth,
                                             hitTestColorKey: colorKey)
                    } else {
                        obj = RectangleShape(from: start, to: snappedEnd,
                                             color: currentColor,
                                             lineWidth: currentLineWidth,
                                             hitTestColorKey: colorKey)
                    }

                case .circle:
                    if drawingFromCenter {
                        let r = hypot(snappedEnd.x - start.x, snappedEnd.y - start.y)
                        obj = CircleShape(center: start, radiusX: max(r, 3),
                                          radiusY: max(r, 3),
                                          color: currentColor,
                                          lineWidth: currentLineWidth,
                                          hitTestColorKey: colorKey)
                    } else {
                        let centerPt = CGPoint(x: (start.x + snappedEnd.x) / 2,
                                               y: (start.y + snappedEnd.y) / 2)
                        let r = max(abs(snappedEnd.x - start.x), abs(snappedEnd.y - start.y)) / 2
                        obj = CircleShape(center: centerPt, radiusX: max(r, 3),
                                          radiusY: max(r, 3),
                                          color: currentColor,
                                          lineWidth: currentLineWidth,
                                          hitTestColorKey: colorKey)
                    }

                case .ellipse:
                    if drawingFromCenter {
                        let rx = abs(snappedEnd.x - start.x)
                        let ry = abs(snappedEnd.y - start.y)
                        obj = CircleShape(center: start, radiusX: max(rx, 3),
                                          radiusY: max(ry, 3),
                                          color: currentColor,
                                          lineWidth: currentLineWidth,
                                          hitTestColorKey: colorKey)
                    } else {
                        let centerPt = CGPoint(x: (start.x + snappedEnd.x) / 2,
                                               y: (start.y + snappedEnd.y) / 2)
                        let rx = abs(snappedEnd.x - start.x) / 2
                        let ry = abs(snappedEnd.y - start.y) / 2
                        obj = CircleShape(center: centerPt, radiusX: max(rx, 3),
                                          radiusY: max(ry, 3),
                                          color: currentColor,
                                          lineWidth: currentLineWidth,
                                          hitTestColorKey: colorKey)
                    }

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

                // 记录 undo
                undoStack.append(.add(colorKey: colorKey))
                redoStack.removeAll()
                contentDidChange()

                // 在 Layer B 上绘制新对象
                hitTestBuffer.drawObject(obj)
                refreshDebugView()
            }
            currentDrawEnd = nil

        case .moving(let colorKey, _):
            if let obj = objects[colorKey], let startCenter = dragStartCenter {
                let totalDelta = CGVector(dx: obj.center.x - startCenter.x,
                                          dy: obj.center.y - startCenter.y)
                if abs(totalDelta.dx) > 0.5 || abs(totalDelta.dy) > 0.5 {
                    // 确认是一次真实移动 → 此时才解除附着，并把"解除前的状态"一并记账
                    if let arrow = obj as? Arrow {
                        arrow.startAttachment = nil
                        arrow.endAttachment = nil
                    }
                    undoStack.append(.move(colorKey: colorKey, delta: totalDelta,
                                           detached: pendingDetach))
                    redoStack.removeAll()
                    contentDidChange()
                } else if totalDelta.dx != 0 || totalDelta.dy != 0 {
                    // 亚像素抖动：不足以记账，就把它完整回退，
                    // 维持"没有记录 ⇔ 没有变化"这个不变量（否则附着丢了却撤不回来）
                    obj.move(by: CGVector(dx: -totalDelta.dx, dy: -totalDelta.dy))
                    restoreDetachedAttachments(pendingDetach)
                    updateAttachedArrows(forParent: colorKey)
                    hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
                    refreshDebugView()
                }
            }
            dragStartCenter = nil
            pendingDetach = nil

        case .rotating(let colorKey, _):
            if abs(rotateStartAngle) > 0.001 {
                undoStack.append(.rotate(colorKey: colorKey, angle: rotateStartAngle))
                redoStack.removeAll()
                contentDidChange()
            } else if rotateStartAngle != 0, let obj = objects[colorKey] {
                // 同 .moving：没记账就把旋转回退掉
                obj.rotate(by: -rotateStartAngle)
                updateAttachedArrows(forParent: colorKey)
                hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
                refreshDebugView()
            }

        case .scaling(let colorKey, _):
            if abs(scaleStartFactor - 1) > 0.001 {
                undoStack.append(.scale(colorKey: colorKey, factor: scaleStartFactor))
                redoStack.removeAll()
                contentDidChange()
            } else if scaleStartFactor != 1, let obj = objects[colorKey] {
                obj.scale(by: 1.0 / scaleStartFactor)
                updateAttachedArrows(forParent: colorKey)
                hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
                refreshDebugView()
            }

        case .idle:
            break
        }

        state = .idle
        activeSnapPoint = nil
        drawingFromCenter = false
        needsDisplay = true
    }    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Cmd+Z = Undo, Cmd+Shift+Z = Redo
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "z" {
                if event.modifierFlags.contains(.shift) {
                    performRedo()
                } else {
                    performUndo()
                }
                return
            }
        }

        if event.keyCode == 53 { // ESC → 取消选中，回到绘制模式
            selectedKey = nil
            state = .idle
            needsDisplay = true
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
            if let key = selectedKey {
                let zOrderBefore = zOrder
                var deletedObjects: [(UInt32, any AnnotationObject)] = []
                if let obj = objects[key] { deletedObjects.append((key, obj)) }
                for (k, o) in objects {
                    if let arrow = o as? Arrow,
                       (arrow.startAttachment?.parentKey == key || arrow.endAttachment?.parentKey == key) {
                        deletedObjects.append((k, o))
                    }
                }
                undoStack.append(.delete(objects: deletedObjects, zOrderSnapshot: zOrderBefore))
                redoStack.removeAll()

                cascadeDelete(parentKey: key)
                objects.removeValue(forKey: key)
                zOrder.removeAll { $0 == key }
                selectedKey = nil
                hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
                refreshDebugView()
                needsDisplay = true
                contentDidChange()
            }
        }
    }

    // MARK: - Undo / Redo

    func performUndo() {
        guard let action = undoStack.popLast() else { return }
        selectedKey = nil

        switch action {
        case .add(let colorKey):
            // 撤销添加 = 删除该对象
            // 保存当前 zOrder（含该对象）供 redo 恢复用
            if let obj = objects[colorKey] {
                redoStack.append(.delete(objects: [(colorKey, obj)], zOrderSnapshot: zOrder))
            }
            objects.removeValue(forKey: colorKey)
            zOrder.removeAll { $0 == colorKey }

        case .delete(let deletedObjects, let zOrderSnapshot):
            // 撤销删除 = 恢复所有被删除的对象和 z-order
            // 保存当前 zOrder（不含已删除对象）供 redo 重新删除用
            let zOrderWithout = zOrder
            for (key, obj) in deletedObjects {
                objects[key] = obj
            }
            zOrder = zOrderSnapshot
            redoStack.append(.delete(objects: deletedObjects, zOrderSnapshot: zOrderWithout))

        case .move(let colorKey, let delta, let detached):
            if let obj = objects[colorKey] {
                let reverseDelta = CGVector(dx: -delta.dx, dy: -delta.dy)
                obj.move(by: reverseDelta)
                restoreDetachedAttachments(detached)        // 撤销移动时把附着关系一起还原
                updateAttachedArrows(forParent: colorKey)
                redoStack.append(.move(colorKey: colorKey, delta: delta, detached: detached))
            }

        case .rotate(let colorKey, let angle):
            if let obj = objects[colorKey] {
                obj.rotate(by: -angle)
                updateAttachedArrows(forParent: colorKey)
                redoStack.append(.rotate(colorKey: colorKey, angle: angle))
            }

        case .scale(let colorKey, let factor):
            if let obj = objects[colorKey] {
                obj.scale(by: 1.0 / factor)
                updateAttachedArrows(forParent: colorKey)
                redoStack.append(.scale(colorKey: colorKey, factor: factor))
            }

        case .restyle(let colorKey, let oldColor, let newColor, let oldLineWidth, let newLineWidth):
            if let obj = objects[colorKey] {
                obj.color = oldColor
                if let w = oldLineWidth { AnnotationView.setLineWidth(w, on: obj) }
                redoStack.append(.restyle(colorKey: colorKey,
                                          oldColor: oldColor, newColor: newColor,
                                          oldLineWidth: oldLineWidth, newLineWidth: newLineWidth))
            }
        }

        contentDidChange()
        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
        needsDisplay = true
    }

    func performRedo() {
        guard let action = redoStack.popLast() else { return }
        selectedKey = nil

        switch action {
        case .add:
            // .add 不再出现在 redo 栈中，保留以保证 switch 完整
            break

        case .delete(let savedObjects, let savedZOrder):
            // 通过检查对象是否存在判断操作方向
            let firstKey = savedObjects[0].0
            if objects[firstKey] != nil {
                // 对象存在 → 重做删除（从 undo .delete 推入）
                undoStack.append(.delete(objects: savedObjects, zOrderSnapshot: zOrder))
                for (key, _) in savedObjects {
                    objects.removeValue(forKey: key)
                }
                zOrder = savedZOrder
            } else {
                // 对象不存在 → 重做添加（从 undo .add 推入）
                for (key, obj) in savedObjects {
                    objects[key] = obj
                }
                zOrder = savedZOrder
                undoStack.append(.add(colorKey: firstKey))
            }

        case .move(let colorKey, let delta, let detached):
            if let obj = objects[colorKey] {
                obj.move(by: delta)
                if let d = detached, let arrow = obj as? Arrow {   // 重做时同样要解除附着
                    arrow.startAttachment = nil
                    arrow.endAttachment = nil
                    _ = d
                }
                updateAttachedArrows(forParent: colorKey)
                undoStack.append(.move(colorKey: colorKey, delta: delta, detached: detached))
            }

        case .rotate(let colorKey, let angle):
            if let obj = objects[colorKey] {
                obj.rotate(by: angle)
                updateAttachedArrows(forParent: colorKey)
                undoStack.append(.rotate(colorKey: colorKey, angle: angle))
            }

        case .scale(let colorKey, let factor):
            if let obj = objects[colorKey] {
                obj.scale(by: factor)
                updateAttachedArrows(forParent: colorKey)
                undoStack.append(.scale(colorKey: colorKey, factor: factor))
            }

        case .restyle(let colorKey, let oldColor, let newColor, let oldLineWidth, let newLineWidth):
            if let obj = objects[colorKey] {
                obj.color = newColor
                if let w = newLineWidth { AnnotationView.setLineWidth(w, on: obj) }
                undoStack.append(.restyle(colorKey: colorKey,
                                          oldColor: oldColor, newColor: newColor,
                                          oldLineWidth: oldLineWidth, newLineWidth: newLineWidth))
            }
        }

        contentDidChange()
        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
        needsDisplay = true
    }

    // MARK: - Drawing (Layer A)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 绘制底图 (Layer O)
        let imageRect = CGRect(origin: .zero, size: baseImage.size)
        baseImage.draw(in: imageRect)

        // 2. 绘制 Spotlight 遮罩（半透明遮盖 + 挖空高亮区域）
        //
        // 遮罩**只在这一处**铺。正在拖拽的聚光灯也并入同一批路径，
        // 而不是留给 drawPreview 再铺一层 —— 否则两层 0.55 黑会叠成 0.20，
        // 预览比松手后的成品黑一倍（实测 0.204 vs 0.451）。
        drawSpotlightOverlay(in: ctx, includingPreview: previewSpotlightPath())

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
        let box = obj.boundingBox
        let padding: CGFloat = 4

        // 1. 发光选中框（蓝色阴影 + 虚线边框）
        ctx.saveGState()
        let selRect = box.insetBy(dx: -padding, dy: -padding)
        ctx.setShadow(offset: .zero, blur: 8, color: NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        let selPath = CGPath(roundedRect: selRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(selPath)
        ctx.strokePath()
        ctx.restoreGState()

        // 2. 四角手柄点
        let handleSize: CGFloat = 6
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [])

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

        // 3. 右上角删除叉号按钮
        let deleteSize: CGFloat = 16
        let deleteCenter = CGPoint(x: selRect.maxX + deleteSize * 0.3,
                                    y: selRect.maxY + deleteSize * 0.3)
        // 红色圆底
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        let deleteRect = CGRect(x: deleteCenter.x - deleteSize / 2,
                                y: deleteCenter.y - deleteSize / 2,
                                width: deleteSize, height: deleteSize)
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fillEllipse(in: deleteRect)
        ctx.restoreGState()

        // 白色叉号
        let crossSize: CGFloat = 4
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: deleteCenter.x - crossSize, y: deleteCenter.y - crossSize))
        ctx.addLine(to: CGPoint(x: deleteCenter.x + crossSize, y: deleteCenter.y + crossSize))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: deleteCenter.x - crossSize, y: deleteCenter.y + crossSize))
        ctx.addLine(to: CGPoint(x: deleteCenter.x + crossSize, y: deleteCenter.y - crossSize))
        ctx.strokePath()
    }

    private func drawPreview(tool: DrawingTool, start: CGPoint, end: CGPoint, in ctx: CGContext) {
        switch tool {
        case .arrow:
            let preview = Arrow(startPoint: start, endPoint: end,
                                color: currentColor, lineWidth: currentLineWidth,
                                hitTestColorKey: 0, style: currentArrowStyle)
            preview.draw(in: ctx)

        case .rectangle:
            if drawingFromCenter {
                let hw = abs(end.x - start.x)
                let hh = abs(end.y - start.y)
                let preview = RectangleShape(center: start, width: max(hw * 2, 2),
                                              height: max(hh * 2, 2),
                                              color: currentColor,
                                              lineWidth: currentLineWidth,
                                              hitTestColorKey: 0)
                preview.draw(in: ctx)
            } else {
                let preview = RectangleShape(from: start, to: end,
                                              color: currentColor,
                                              lineWidth: currentLineWidth,
                                              hitTestColorKey: 0)
                preview.draw(in: ctx)
            }

        case .circle:
            if drawingFromCenter {
                let r = hypot(end.x - start.x, end.y - start.y)
                let preview = CircleShape(center: start, radiusX: max(r, 1),
                                           radiusY: max(r, 1),
                                           color: currentColor,
                                           lineWidth: currentLineWidth,
                                           hitTestColorKey: 0)
                preview.draw(in: ctx)
            } else {
                let centerPt = CGPoint(x: (start.x + end.x) / 2,
                                       y: (start.y + end.y) / 2)
                let r = max(abs(end.x - start.x), abs(end.y - start.y)) / 2
                let preview = CircleShape(center: centerPt, radiusX: max(r, 1),
                                           radiusY: max(r, 1),
                                           color: currentColor,
                                           lineWidth: currentLineWidth,
                                           hitTestColorKey: 0)
                preview.draw(in: ctx)
            }

        case .ellipse:
            if drawingFromCenter {
                let rx = abs(end.x - start.x)
                let ry = abs(end.y - start.y)
                let preview = CircleShape(center: start, radiusX: max(rx, 1),
                                           radiusY: max(ry, 1),
                                           color: currentColor,
                                           lineWidth: currentLineWidth,
                                           hitTestColorKey: 0)
                preview.draw(in: ctx)
            } else {
                let centerPt = CGPoint(x: (start.x + end.x) / 2,
                                       y: (start.y + end.y) / 2)
                let rx = abs(end.x - start.x) / 2
                let ry = abs(end.y - start.y) / 2
                let preview = CircleShape(center: centerPt, radiusX: max(rx, 1),
                                           radiusY: max(ry, 1),
                                           color: currentColor,
                                           lineWidth: currentLineWidth,
                                           hitTestColorKey: 0)
                preview.draw(in: ctx)
            }

        case .stamp:
            break  // stamp 是单击放置，不需要拖拽预览

        case .spotlight:
            // 遮罩已在 draw(_:) 的 drawSpotlightOverlay 里连同预览路径一次铺好，
            // 这里只补那条虚线边框（边框属于编辑器提示，导出时会被 drawForExport 去掉）
            guard let spotPath = previewSpotlightPath() else { break }
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.addPath(spotPath)
            ctx.strokePath()
            ctx.restoreGState()
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

    /// Spotlight 的圆角矩形路径（世界坐标）
    private func spotlightPath(_ spot: SpotlightShape) -> CGPath {
        var transform = CGAffineTransform.identity
            .translatedBy(x: spot.center.x, y: spot.center.y)
            .rotated(by: spot.rotation)
        let localRect = CGRect(x: -spot.width / 2, y: -spot.height / 2,
                               width: spot.width, height: spot.height)
        return CGPath(roundedRect: localRect,
                      cornerWidth: spot.cornerRadius, cornerHeight: spot.cornerRadius,
                      transform: &transform)
    }

    /// 绘制遮罩：全图半透明压暗，再把聚光灯区域"挖空"。
    ///
    /// 关键点：挖空必须在 `beginTransparencyLayer` 里用 `.clear` 做。
    /// - 直接 `.clear` 会把已经画好的底图一起擦掉；
    /// - 用 `.evenOdd` 裁剪虽然能挖空，但**多个聚光灯重叠处会被重新算成"要压暗"**，
    ///   于是两块聚光灯的交集反而变黑（README 明确宣称支持叠加）。
    private func drawSpotlightMask(in ctx: CGContext, paths: [CGPath], imageRect: CGRect) {
        guard !paths.isEmpty else { return }

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(imageRect)
        ctx.setBlendMode(.clear)
        for path in paths {
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 高亮区提亮：把所有路径并成一条子路径一次填充，
        // 非零环绕规则下重叠子路径算并集 —— 重叠处只叠加一次白光。
        let union = CGMutablePath()
        for path in paths { union.addPath(path) }
        ctx.saveGState()
        ctx.addPath(union)
        ctx.clip()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.fill(imageRect)
        ctx.restoreGState()
    }

    /// 绘制 Spotlight 遮罩：全图半透明遮盖，挖空所有 SpotlightShape 区域。
    ///
    /// `includingPreview` 用于把"正在拖拽的那一个"并入同一批路径 —— 遮罩必须一次铺完，
    /// 分两次铺会叠加压暗。
    private func drawSpotlightOverlay(in ctx: CGContext, includingPreview preview: CGPath? = nil) {
        var paths = zOrder.compactMap { objects[$0] as? SpotlightShape }.map { spotlightPath($0) }
        if let preview = preview { paths.append(preview) }
        guard !paths.isEmpty else { return }
        drawSpotlightMask(in: ctx,
                          paths: paths,
                          imageRect: CGRect(origin: .zero, size: baseImage.size))
    }

    /// 正在拖拽中的聚光灯路径（未松手时才有值）
    private func previewSpotlightPath() -> CGPath? {
        guard case .drawing(let tool, let start) = state, tool == .spotlight,
              let end = currentDrawEnd else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        return CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
    }

    // MARK: - Object Attachment

    /// 检测一个点附近是否有可附着的形状，返回 Attachment 或 nil
    private func detectAttachment(at point: CGPoint, excludeKey: UInt32?) -> Attachment? {
        var bestDist: CGFloat = attachThreshold
        var bestAttachment: Attachment?

        for (key, obj) in objects {
            if key == excludeKey { continue }
            // 箭头不作为父对象；聚光灯也不作父对象 ——
            // 它没有 pointOnPerimeter，附着上去之后端点永远不会跟随。
            if obj is Arrow || obj is SpotlightShape { continue }

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
            let local = rotatePoint(point, around: circle.center, by: -circle.rotation)
            let dx = local.x - circle.center.x
            let dy = local.y - circle.center.y
            var angle = atan2(dy / circle.radiusY, dx / circle.radiusX)
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

    /// 撤销"移动箭头"时把当初被解除的附着装回去
    private func restoreDetachedAttachments(_ snapshot: DetachedAttachments?) {
        guard let snapshot = snapshot, let arrow = objects[snapshot.key] as? Arrow else { return }
        arrow.startAttachment = snapshot.start
        arrow.endAttachment = snapshot.end
        if let att = arrow.startAttachment, let pos = resolveAttachmentPosition(att) {
            arrow.startPoint = pos
        }
        if let att = arrow.endAttachment, let pos = resolveAttachmentPosition(att) {
            arrow.endPoint = pos
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

    /// 刷新 Layer B 调试面板（未挂载调试面板时零开销）
    func refreshDebugView() {
        guard let imageView = debugImageView else { return }
        let debugImage = hitTestBuffer.debugVisualization(objects: objects, zOrder: zOrder)
        imageView.image = debugImage
    }

    // MARK: - Export

    /// 源图像的像素尺寸（导出分辨率以此为准，避免导出分辨率随"当前显示器"变化）
    private var basePixelSize: CGSize {
        if let explicit = sourcePixelSize, explicit.width >= 1, explicit.height >= 1 {
            return explicit
        }
        let best = baseImage.representations
            .filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        if let best = best {
            return CGSize(width: best.pixelsWide, height: best.pixelsHigh)
        }
        // 兜底（正常路径不会走到：AppDelegate 一定会传 pixelSize）：
        // 不再依赖任何"当前屏幕"，按 2x 估算，保证导出分辨率与显示器无关。
        let scale: CGFloat = 2
        return CGSize(width: baseImage.size.width * scale, height: baseImage.size.height * scale)
    }

    /// 生成最终合成图片（底图 + 所有标注对象）
    ///
    /// 用显式的 `NSBitmapImageRep` 而不是 `NSImage.lockFocus()`：
    /// lockFocus 的分辨率取决于**当前显示器**的 backingScaleFactor，
    /// 在 1x 外接屏上标注 2x 截图时导出的 PNG 会掉一半像素。
    func compositeImage() -> NSImage {
        // 这次导出覆盖了当前内容 → 之后再关窗就不必再问"要不要放弃标注"
        exportedVersion = contentVersion

        let pointSize = baseImage.size
        let pixels = basePixelSize
        let scale = max(pixels.width / max(pointSize.width, 1), 0.01)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: max(Int(pixels.width), 1),
                                         pixelsHigh: max(Int(pixels.height), 1),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            let fallback = NSImage(size: pointSize)
            fallback.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext { render(into: ctx, pointSize: pointSize) }
            fallback.unlockFocus()
            return fallback
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)          // 之后依旧按"点"坐标绘制
            render(into: ctx, pointSize: pointSize)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    /// 把底图、聚光灯遮罩、所有标注对象、水印渲染进给定上下文（坐标为"点"）
    private func render(into ctx: CGContext, pointSize: NSSize) {
        let rect = CGRect(origin: .zero, size: pointSize)
        baseImage.draw(in: rect)
        drawSpotlightOverlay(in: ctx)
        for key in zOrder {
            if let obj = objects[key] {
                // 用 drawForExport 而不是 draw：聚光灯的虚线边框是编辑器 UI，
                // 不能出现在导出图里（其余类型默认行为与 draw 相同）
                obj.drawForExport(in: ctx)
            }
        }
        if watermarkConfig.enabled && !watermarkConfig.text.isEmpty {
            drawWatermark(in: ctx, size: pointSize)
        }
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
