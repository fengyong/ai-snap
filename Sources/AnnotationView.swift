import Cocoa

/// 标注画布 — 支持多形状类型的双图层 Color Picking 方案
class AnnotationView: NSView {
    // Layer O: 原始截图。非 private：吸附与渲染的扩展文件要用
    let baseImage: NSImage
    // Map<唯一颜色Key, AnnotationObject>
    /// 画布上的全部标注对象。**非 private**：拆分到其它文件的扩展要用
    /// （附着、吸附、撤销重做各在独立文件里）。Swift 没有比 internal 更细的
    /// 同模块访问级别，所以拆文件必然要放宽这一层。
    var objects: [UInt32: any AnnotationObject] = [:]
    // Z 序：从底到顶的 colorKey 数组。非 private，同上（扩展文件要用）
    var zOrder: [UInt32] = []
    // Layer B: 隐藏的 hit test 缓冲区。非 private，同上
    var hitTestBuffer: HitTestBuffer

    private var state: CanvasState = .idle
    private var currentDrawEnd: CGPoint?

    // 当前工具和样式
    //
    // 这几项在改动时立刻写入 Preferences（didSet），因此不需要任何显式保存调用 ——
    // 无论从工具栏、菜单还是将来的快捷键修改，持久化都自动跟上。
    // `currentTool` 不在这里持久化：它按工具栏按钮 tag 存，由 AnnotationWindow 负责。
    var currentTool: DrawingTool = .arrow

    var currentColor: NSColor = .red {
        didSet {
            guard currentColor != oldValue else { return }
            Preferences.shared.color = currentColor
        }
    }

    var currentLineWidth: CGFloat = 15.0 {
        didSet {
            guard currentLineWidth != oldValue else { return }
            Preferences.shared.lineWidth = currentLineWidth
        }
    }

    /// 新建矩形/椭圆使用的描边线型。
    /// 箭头的线型不走这里 —— 它由 `ArrowStyle` 预设携带（「箭头样式」里已有
    /// 虚线、点菱等预设），两处各管一套就不会互相覆盖。
    var currentLineStyle: LineStyle = .solid {
        didSet {
            guard currentLineStyle != oldValue else { return }
            Preferences.shared.lineStyle = currentLineStyle
        }
    }

    var currentArrowStyle: ArrowStyle = .default {
        didSet {
            guard currentArrowStyle != oldValue else { return }
            Preferences.shared.arrowStyle = currentArrowStyle
        }
    }

    // 水印配置
    var watermarkConfig = WatermarkConfig() {
        didSet {
            // WatermarkConfig 里只有 text / enabled 有 UI 入口，逐项写回；
            // 其余（字号、颜色、平铺、角度）保持代码默认值，不写入也不用读回。
            if watermarkConfig.text != oldValue.text {
                Preferences.shared.watermarkText = watermarkConfig.text
            }
            if watermarkConfig.enabled != oldValue.enabled {
                Preferences.shared.watermarkEnabled = watermarkConfig.enabled
            }
        }
    }

    // 当前被选中的对象 key。非 private：撤销/重做扩展会清空它
    var selectedKey: UInt32?

    // 点捕捉：当前活跃的吸附点（用于可视化）
    // 非 private：吸附扩展文件要用
    var activeSnapPoint: CGPoint?
    let snapThreshold: CGFloat = 12.0
    // 起始点是否吸附到了 snap point → 以该点为中心绘制
    private var drawingFromCenter: Bool = false

    // Undo/Redo 栈。非 private：撤销/重做已拆到 AnnotationView+UndoRedo.swift
    var undoStack: [UndoAction] = []
    var redoStack: [UndoAction] = []
    // 拖拽操作前的起始中心，用于计算总 delta
    private var dragStartCenter: CGPoint?
    private var rotateStartAngle: CGFloat = 0
    private var scaleStartFactor: CGFloat = 1

    // 调试面板：外部挂载的 NSImageView，用于实时显示 Layer B 可视化
    weak var debugImageView: NSImageView?

    // MARK: 文字标注的行内编辑
    //
    // 这三个必须存在类里而不是扩展文件里（extension 不能加实例存储属性），
    // 编辑逻辑本身在 AnnotationView+TextEditing.swift。
    /// 正在编辑的输入框（nil = 没有在编辑）
    var textEditingField: NSTextField?
    /// 正在编辑的对象 key
    var textEditingKey: UInt32?
    /// 进入编辑前的原文，用于 Esc 取消与撤销
    var textEditingOriginalText: String = ""

    init(image: NSImage) {
        self.baseImage = image
        let size = image.size
        self.hitTestBuffer = HitTestBuffer(size: size)
        super.init(frame: NSRect(origin: .zero, size: size))

        // 从偏好恢复上次使用的样式。
        //
        // 不恢复的：currentTool（由 AnnotationWindow 按工具栏 tag 恢复）、
        // 选区 / 撤销栈 / 已画对象 —— 那些属于单次会话，跨会话恢复反而突兀。
        //
        // 注意：属性观察器在初始化期间不会触发，所以这里不会把刚读出来的值又写回去。
        let prefs = Preferences.shared
        currentColor = prefs.color
        currentLineWidth = prefs.lineWidth
        currentLineStyle = prefs.lineStyle
        currentArrowStyle = prefs.arrowStyle
        watermarkConfig = prefs.watermarkConfig
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
                return
            }
        }

        // 已选中对象时，修饰键触发旋转/缩放
        if let key = selectedKey, let obj = objects[key] {
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
            // 双击文字 → 原地重新编辑（改错字不必删了重画）
            if event.clickCount >= 2, let textShape = obj as? TextShape {
                selectedKey = colorKey
                beginEditingText(textShape, key: colorKey)
                needsDisplay = true
                return
            }
            // 命中已有对象 → 进入移动模式
            let offset = CGVector(dx: point.x - obj.center.x,
                                  dy: point.y - obj.center.y)
            state = .moving(colorKey: colorKey, grabOffset: offset)
            selectedKey = colorKey
            dragStartCenter = obj.center
        } else if placeClickToolObject(at: point) {
            // 序号 / 贴纸这类单击放置的工具：对象已放置并选中
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
            rotateStartAngle += deltaAngle
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
                    scaleStartFactor *= factor
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
                // 具体形状的构造交给工具自己的 handler（见 Sources/Tools/）。
                // 画布只负责：配色 key、登记对象、记撤销、重绘。
                guard let obj = ToolRegistry.handler(for: tool)?
                    .makeObject(from: start, to: snappedEnd, tool: tool,
                                context: toolContext(colorKey: colorKey)) else {
                    // 该工具不由拖拽构造（序号/贴纸是单击放置）
                    currentDrawEnd = nil
                    state = .idle
                    needsDisplay = true
                    return
                }
                registerNewObject(obj, colorKey: colorKey)
            }
            currentDrawEnd = nil

        case .moving(let colorKey, _):
            if let obj = objects[colorKey], let startCenter = dragStartCenter {
                let totalDelta = CGVector(dx: obj.center.x - startCenter.x,
                                          dy: obj.center.y - startCenter.y)
                if abs(totalDelta.dx) > 0.5 || abs(totalDelta.dy) > 0.5 {
                    undoStack.append(.move(colorKey: colorKey, delta: totalDelta))
                    redoStack.removeAll()
                }
            }
            dragStartCenter = nil

        case .rotating(let colorKey, _):
            if abs(rotateStartAngle) > 0.001 {
                undoStack.append(.rotate(colorKey: colorKey, angle: rotateStartAngle))
                redoStack.removeAll()
            }

        case .scaling(let colorKey, _):
            if abs(scaleStartFactor - 1) > 0.001 {
                undoStack.append(.scale(colorKey: colorKey, factor: scaleStartFactor))
                redoStack.removeAll()
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
        if handleCommandKey(event) { return }
        if handlePlainKey(event) { return }
        // 不认识的键交回 super，保留系统默认行为（例如未处理键的提示音）
        super.keyDown(with: event)
    }

    /// ⌘ 组合键。返回是否已处理。
    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }

        // 必须先 lowercased() 再比对：`charactersIgnoringModifiers` 会**保留 Shift 的影响**，
        // ⌘⇧Z 拿到的是 "Z" 而不是 "z"。原实现直接与 "z" 比较，于是「重做」那一支
        // 永远不会触发 —— 只有当菜单的 ⌘⇧Z 生效时才碰巧能用。
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            if event.modifierFlags.contains(.shift) {
                performRedo()
            } else {
                performUndo()
            }
            return true
        case "s":
            (window as? AnnotationWindow)?.saveImage()
            return true
        case "c":
            (window as? AnnotationWindow)?.copyImage()
            return true
        default:
            return false
        }
    }

    /// 无修饰键的按键。返回是否已处理。
    private func handlePlainKey(_ event: NSEvent) -> Bool {
        // 带任何修饰键时都不抢：⌘/⌃/⌥ 组合留给菜单或系统
        let hasModifier = !event.modifierFlags
            .intersection([.command, .control, .option]).isEmpty
        if hasModifier { return false }

        switch event.keyCode {
        case 53: // Esc → 取消选中，回到绘制模式
            selectedKey = nil
            state = .idle
            needsDisplay = true
            return true

        case 51, 117: // Delete / Forward Delete
            deleteSelectedObject()
            return true

        case 36, 76: // Return / 小键盘 Enter → 复制并关闭
            (window as? AnnotationWindow)?.copyAndClose()
            return true

        case 48: // Tab / ⇧Tab → 循环切换绘图工具
            (window as? AnnotationWindow)?
                .cycleTool(reverse: event.modifierFlags.contains(.shift))
            return true

        case 99: // F3 → 贴到屏幕上（沿用 Snipaste 的习惯键位）
            (window as? AnnotationWindow)?.pinImage()
            return true

        default:
            break
        }

        // 数字键 1..9 → 直接选中第 N 个绘图工具
        if let chars = event.charactersIgnoringModifiers,
           let digit = Int(chars), digit >= 1, digit <= 9 {
            (window as? AnnotationWindow)?.selectTool(atIndex: digit - 1)
            return true
        }

        return false
    }

    /// 删除当前选中的对象（含挂在它上面的箭头），并记录一步撤销。
    ///
    /// 抽成方法是因为它有多个入口：这里的 Delete 键，以及菜单的「删除选中」。
    func deleteSelectedObject() {
        guard let key = selectedKey else { return }

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
    }

    // MARK: - Undo / Redo

    // performUndo / performRedo 已拆到 AnnotationView+UndoRedo.swift

    // MARK: - 序号标注

    /// 下一个序号标注的编号 = 现有最大编号 + 1。
    ///
    /// 取最大值而非"数量 + 1"，是为了让删除后新建的编号不会与已有的撞号；
    /// 同时也避免删除中间某个序号时，其余序号的显示数字发生跳动。
    private func nextStepNumber() -> Int {
        var maxNumber = 0
        for (_, object) in objects {
            if let badge = object as? StepBadge {
                maxNumber = max(maxNumber, badge.number)
            }
        }
        return maxNumber + 1
    }

    // MARK: - Drawing (Layer A)

    // `draw(_:)` 是 NSView 的 override，而 Swift 不允许在 extension 里写 override，
    // 所以它必须留在类体内当渲染入口；它调用的绘制细节
    // （drawSelectionHandles / drawPreview）在 AnnotationView+Rendering.swift。
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

    // MARK: - 工具上下文与对象登记

    /// 把画布的当前设置打包给工具 handler。
    ///
    /// 两个闭包是必要的妥协：端点吸附与序号编号都需要访问画布上的对象表，
    /// 而 handler 不该持有画布引用（否则拆分就白做了）。
    /// 非 private：AnnotationView+Rendering.swift 的拖拽预览要用。
    func toolContext(colorKey: UInt32) -> ToolContext {
        ToolContext(
            color: currentColor,
            lineWidth: currentLineWidth,
            lineStyle: currentLineStyle,
            arrowStyle: currentArrowStyle,
            drawingFromCenter: drawingFromCenter,
            canvasSize: baseImage.size,
            colorKey: colorKey,
            detectAttachment: { [weak self] point in
                self?.detectAttachment(at: point, excludeKey: colorKey)
            },
            resolveAttachmentPosition: { [weak self] attachment in
                self?.resolveAttachmentPosition(attachment)
            },
            nextStepNumber: { [weak self] in
                self?.nextStepNumber() ?? 1
            }
        )
    }

    /// 把新对象登记进画布：入表、追加 z 序、记一步撤销、画进 Layer B。
    ///
    /// 拖拽构造与单击放置共用这一处，避免两份「登记 + 撤销 + 重绘」的重复 ——
    /// 这类重复最容易出的问题是漏掉其中一步（比如忘了往 Layer B 画，新对象就选不中）。
    private func registerNewObject(_ obj: any AnnotationObject,
                                   colorKey: UInt32,
                                   selectAfterPlacing: Bool = false) {
        objects[colorKey] = obj
        zOrder.append(colorKey)
        undoStack.append(.add(colorKey: colorKey))
        redoStack.removeAll()
        hitTestBuffer.drawObject(obj)
        refreshDebugView()
        if selectAfterPlacing {
            selectedKey = colorKey
            state = .idle
        }
        needsDisplay = true
    }

    /// 单击放置类工具（序号、贴纸）。返回是否真的放置了对象。
    @discardableResult
    private func placeClickToolObject(at point: CGPoint) -> Bool {
        guard let handler = ToolRegistry.handler(for: currentTool) else { return false }
        let colorKey = hitTestBuffer.generateUniqueColorKey()
        guard let obj = handler.placeObject(at: point, tool: currentTool,
                                            context: toolContext(colorKey: colorKey)) else {
            return false
        }
        // 单击放置完就选中它，方便立刻调整位置
        registerNewObject(obj, colorKey: colorKey, selectAfterPlacing: true)

        // 文字标注放完立刻进入输入状态 —— 否则落一个空文字在画布上，
        // 用户还得再双击一次才能打字
        if let textShape = obj as? TextShape {
            beginEditingText(textShape, key: colorKey)
        }
        return true
    }

    // drawPreview 已移到 AnnotationView+Rendering.swift

    // MARK: - Object Snap

    // 吸附查询与两个叠加层（吸附指示器、聚光灯遮罩）已拆到 AnnotationView+Snapping.swift

    // MARK: - 附着

    // 附着相关的方法已拆到 AnnotationView+Attachments.swift

    // MARK: - Debug Visualization

    /// 刷新右侧的 Layer B 调试面板。非 private：撤销/重做扩展要用
    func refreshDebugView() {
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
