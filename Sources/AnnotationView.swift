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
    var currentTool: DrawingTool = .arrow {
        didSet {
            // 切走橡皮擦时收掉笔刷圆环，否则屏幕上会一直留着一个圈
            if currentTool != .eraser {
                eraseCursor = nil
                needsDisplay = true
            }
            // 取色器同理：切走后放大镜要消失
            if currentTool != .picker {
                pickerPoint = nil
                pickerPreview = nil
                needsDisplay = true
            }
        }
    }

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

    // MARK: 橡皮擦状态
    //
    // 橡皮擦不是"拖拽构造一个对象"，而是边拖边删，所以它有自己的一组状态，
    // 走的也是 `.erasing` 而不是 `.drawing`。整条拖拽路径上的删除最后合并成一步撤销。
    /// 这一笔已经抹掉的对象（连同它们挂着的箭头），攒到 mouseUp 一起记撤销
    private var eraseDeleted: [(UInt32, any AnnotationObject)] = []
    /// 这一笔开始前的 z 序：撤销时要连叠放次序一起还原
    private var eraseZOrderBefore: [UInt32] = []
    private var lastErasePoint: CGPoint?
    /// 笔刷半径（点）。**预览画的圆环与真实判定范围共用这一个值** ——
    /// 分两处写，圆环就会变成骗人的：画得很大却擦不掉环内的对象。
    let eraserRadius: CGFloat = 6
    /// 笔刷圆环的位置（鼠标当前点）
    private var eraseCursor: CGPoint?

    // MARK: 取色器状态
    //
    // 与橡皮擦同类：不产生对象，而是持续读取光标处的像素。放大镜要读一小片区域，
    // 所以还需要一个像素采样器（首次使用时才把整幅图铺成可随机访问的字节）。
    /// 放大镜的位置（鼠标当前点）
    private var pickerPoint: CGPoint?
    /// 光标处的颜色（拖拽中实时更新）。**只在 mouseUp 时才写回 `currentColor`** ——
    /// 属性观察器会把每次写入都落到 UserDefaults，拖拽中每帧写一次纯属浪费。
    private var pickerPreview: NSColor?
    private lazy var pixelSampler = baseCGImage.flatMap { ImagePixelSampler(image: $0) }

    // MARK: 文字识别的结果框
    //
    // 只做**显示层**的高亮，不生成标注对象：它们不该被导出、不该进撤销栈、
    // 也不该被橡皮擦当对象擦掉。识别坐标将来要变成真对象的话，那是「智能脱敏」的事。
    /// 最近一次识别出的文字外框（画布坐标）
    private(set) var ocrHighlights: [CGRect] = []

    /// 显示识别结果框（传空数组即清除）
    func showOCRHighlights(_ rects: [CGRect]) {
        ocrHighlights = rects
        needsDisplay = true
    }

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

    // MARK: - 底图的像素访问（打码用）

    /// 底图的 `CGImage` 形式。只转一次：`cgImage(forProposedRect:context:hints:)`
    /// 每次调用都要走一遍 NSImage 的图像表示，放进每帧的绘制路径里是白给的开销。
    private(set) lazy var baseCGImage: CGImage? = {
        var rect = CGRect(origin: .zero, size: baseImage.size)
        return baseImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }()

    /// 「画布点 → 底图像素」的倍率（Retina 上通常是 2）。
    ///
    /// 用两者**实测尺寸相除**反推，而不是取 `backingScaleFactor`：
    /// 万一捕获返回的尺寸与屏幕倍率不一致（跨屏、降级 1x），除法仍然是对的。
    private(set) lazy var pixelScale: CGFloat = {
        guard let cg = baseCGImage, baseImage.size.width > 0 else { return 1 }
        return CGFloat(cg.width) / baseImage.size.width
    }()

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

        // 橡皮擦：跟随鼠标画笔刷圆环，让用户看得见"擦得到哪里"
        if currentTool == .eraser {
            eraseCursor = point
            needsDisplay = true
            return
        }

        // 取色器：跟随鼠标显示放大镜与当前色值
        if currentTool == .picker {
            updatePicker(at: point)
            needsDisplay = true
            return
        }

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

        // 橡皮擦优先于下面所有分支：选中态、⌥ 旋转、⇧ 缩放都不该在这个工具下生效 ——
        // 否则会变成「选了橡皮擦，一拖却在转对象」。
        if currentTool == .eraser {
            beginEraseStroke(at: point)
            return
        }

        // 取色器同理：在画布上点击就是取色，不选中、不移动任何对象
        if currentTool == .picker {
            pickerPoint = point
            updatePicker(at: point)
            state = .picking
            needsDisplay = true
            return
        }

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
                // 与 Delete 键、菜单「删除选中」走同一条路（原先这里是一份复制粘贴的
                // 实现，三处各自维护"收集级联箭头 + 记撤销 + 重绘"迟早会漏掉一步）
                deleteSelectedObject()
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

        case .erasing:
            eraseCursor = point
            continueEraseStroke(to: point)

        case .picking:
            pickerPoint = point
            updatePicker(at: point)
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

        case .erasing:
            // 整笔拖拽合并成一步撤销：否则按一次 ⌘Z 只退回一个对象，
            // 想退回原状得按十几次 —— 那等于撤销功能对橡皮擦不可用。
            if !eraseDeleted.isEmpty {
                undoStack.append(.delete(objects: eraseDeleted,
                                         zOrderSnapshot: eraseZOrderBefore))
                redoStack.removeAll()
            }
            eraseDeleted = []
            eraseZOrderBefore = []
            lastErasePoint = nil

        case .picking:
            // 到这里才把取到的颜色写回当前颜色（一次 UserDefaults 写入），
            // 并交给窗口去做「复制 HEX + 提示」—— 画布不该管剪贴板。
            // 先按松手位置再取一次：拖到最后那一小段可能没有 mouseDragged 事件。
            updatePicker(at: point)
            if let color = pickerPreview, let rgb = rgbAtCanvasPoint(point) {
                currentColor = color
                (window as? AnnotationWindow)?.didPickColor(
                    hex: ImagePixelSampler.hex(r: rgb.r, g: rgb.g, b: rgb.b))
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
        case "d":
            // ⌘D：显示/隐藏 Layer B 调试面板。它是开发期工具、默认隐藏 ——
            // 普通用户看到右侧一块莫名的深色分屏只会困惑。
            (window as? AnnotationWindow)?.toggleDebugPanel()
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
            // 识别结果框也一并收掉：它是"看一眼就好"的临时信息，
            // Esc 在用户心里就是"清掉眼前这些临时东西"
            if !ocrHighlights.isEmpty {
                ocrHighlights = []
            }
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
    /// 抽成方法是因为它有多个入口：Delete 键、菜单的「删除选中」、以及选中框右上角的叉号。
    func deleteSelectedObject() {
        guard let key = selectedKey else { return }

        let zOrderBefore = zOrder
        let taken = takeOutOfCanvas(key)
        guard !taken.isEmpty else { return }

        undoStack.append(.delete(objects: taken, zOrderSnapshot: zOrderBefore))
        redoStack.removeAll()
        selectedKey = nil

        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
        needsDisplay = true
    }

    /// 把对象（连同挂在它上面的箭头）从画布上摘下来，返回被摘掉的东西。
    ///
    /// **不记撤销** —— 因为不同调用方要的撤销粒度不同：删除键是"一次删一个"，
    /// 橡皮擦是"整笔拖拽合成一步"。把"摘除"和"怎么记撤销"分开，两条路才能共用同一份
    /// 级联逻辑；否则「删除时要连箭头一起删」这条规则会在三处各写一遍，漏一处就是
    /// 画布上留下一个吊在不存在父对象上的箭头。
    @discardableResult
    private func takeOutOfCanvas(_ key: UInt32) -> [(UInt32, any AnnotationObject)] {
        var taken: [(UInt32, any AnnotationObject)] = []
        if let obj = objects[key] { taken.append((key, obj)) }
        for (k, o) in objects {
            guard k != key, let arrow = o as? Arrow else { continue }
            if arrow.startAttachment?.parentKey == key || arrow.endAttachment?.parentKey == key {
                taken.append((k, o))
            }
        }
        let removedKeys = Set(taken.map { $0.0 })
        for k in removedKeys { objects.removeValue(forKey: k) }
        zOrder.removeAll { removedKeys.contains($0) }
        return taken
    }

    // MARK: - 橡皮擦

    private func beginEraseStroke(at point: CGPoint) {
        // 记下这一笔开始前的 z 序：撤销要连叠放次序一起还原，否则撤销之后
        // 对象会跑到别的对象上面去，看着像"撤销把它挪了位置"
        eraseZOrderBefore = zOrder
        eraseDeleted = []
        lastErasePoint = point
        eraseCursor = point
        state = .erasing
        erase(at: point)
        needsDisplay = true
    }

    private func continueEraseStroke(to point: CGPoint) {
        // 沿路径补点采样：鼠标移动事件是离散的，快速拖动时相邻两个事件可能隔了几十点，
        // 只按当前位置判定会漏掉中间掠过的对象 —— 表现是"擦过去却没擦掉"。
        let step: CGFloat = 3
        let from = lastErasePoint ?? point
        let distance = hypot(point.x - from.x, point.y - from.y)
        if distance > step {
            let count = Int(distance / step)
            for i in 1...count {
                let t = CGFloat(i) / CGFloat(count + 1)
                erase(at: CGPoint(x: from.x + (point.x - from.x) * t,
                                  y: from.y + (point.y - from.y) * t))
            }
        }
        erase(at: point)
        lastErasePoint = point
        needsDisplay = true
    }

    /// 抹掉笔刷范围内的对象。
    ///
    /// 取「中心 + 半径 R 上八个方向」共 9 个采样点，而不是只取中心一点：
    /// 预览画的是一个半径 R 的圆环，若只按中心判定，那个圆环就是**骗人的** ——
    /// 环里的对象擦不掉，用户会以为橡皮擦坏了。
    private func erase(at point: CGPoint) {
        var picked: Set<UInt32> = []
        let center = hitTestBuffer.pickColorKey(at: point)
        if center != 0 { picked.insert(center) }
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let sample = CGPoint(x: point.x + cos(angle) * eraserRadius,
                                 y: point.y + sin(angle) * eraserRadius)
            let key = hitTestBuffer.pickColorKey(at: sample)
            if key != 0 { picked.insert(key) }
        }
        guard !picked.isEmpty else { return }

        // 先在 Layer B 上把所有采样点都取完、再动手删：边删边取会让后面的采样
        // 落到"已经被删掉的位置"，同一笔里的判定结果就取决于顺序了。
        var taken: [(UInt32, any AnnotationObject)] = []
        for key in picked where objects[key] != nil {
            taken.append(contentsOf: takeOutOfCanvas(key))
        }
        guard !taken.isEmpty else { return }

        eraseDeleted.append(contentsOf: taken)
        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
    }

    /// 橡皮擦的笔刷圆环。半径与真实判定范围共用 `eraserRadius`。
    private func drawEraseCursor(in ctx: CGContext) {
        guard let cursor = eraseCursor else { return }
        let r = eraserRadius
        let rect = CGRect(x: cursor.x - r, y: cursor.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.fillEllipse(in: rect)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()
    }

    // MARK: - 取色器

    /// 读取光标处的颜色，并刷新放大镜预览。
    ///
    /// 取色只取自**原始截图**，不包含已经画上去的标注。这样"这个位置是什么颜色"
    /// 有确定答案，不会随你先前画了什么而变。代价是：想要自己画的那个红色，
    /// 得从调色板里选 —— 这个取舍写在帮助里。
    private func updatePicker(at point: CGPoint) {
        pickerPoint = point
        guard let rgb = rgbAtCanvasPoint(point) else {
            pickerPreview = nil
            return
        }
        pickerPreview = NSColor(srgbRed: CGFloat(rgb.r) / 255,
                                green: CGFloat(rgb.g) / 255,
                                blue: CGFloat(rgb.b) / 255,
                                alpha: 1)
    }

    /// 画布坐标 → 底图像素 → RGB。换算交给 `ImagePixelSampler.pixelCoordinate`，
    /// 画布这边不重复实现一遍 Y 翻转。
    private func rgbAtCanvasPoint(_ point: CGPoint) -> (r: Int, g: Int, b: Int)? {
        guard let sampler = pixelSampler,
              let px = ImagePixelSampler.pixelCoordinate(
                canvasPoint: point,
                canvasSize: baseImage.size,
                pixelSize: CGSize(width: sampler.pixelWidth,
                                  height: sampler.pixelHeight)) else { return nil }
        return sampler.rgb(atPixelX: px.x, y: px.y)
    }

    /// 取色放大镜 + 色值标签。
    private func drawPickerLoupe(in ctx: CGContext) {
        guard let cursor = pickerPoint, let sampler = pixelSampler else { return }

        let side = 11                       // 奇数 → 被取的那一格正好落在正中间
        let magnified: CGFloat = 132
        let cell = magnified / CGFloat(side)
        let radius = magnified / 2
        let margin: CGFloat = 8

        // 放大镜默认在光标右上；贴近画布边缘时翻到另一侧，避免被裁掉一半
        var center = CGPoint(x: cursor.x + radius + 24, y: cursor.y + radius + 24)
        if center.x + radius > baseImage.size.width - margin {
            center.x = cursor.x - radius - 24
        }
        if center.y + radius > baseImage.size.height - margin {
            center.y = cursor.y - radius - 24
        }
        center.x = max(radius + margin,
                       min(baseImage.size.width - radius - margin, center.x))
        center.y = max(radius + margin,
                       min(baseImage.size.height - radius - margin, center.y))

        let box = CGRect(x: center.x - radius, y: center.y - radius,
                         width: magnified, height: magnified)
        let circle = CGPath(ellipseIn: box, transform: nil)

        // 1. 放大的像素片（最近邻：放大镜里必须是硬边像素格，否则等于什么都没放大）
        ctx.saveGState()
        ctx.addPath(circle)
        ctx.clip()
        if let px = ImagePixelSampler.pixelCoordinate(
            canvasPoint: cursor,
            canvasSize: baseImage.size,
            pixelSize: CGSize(width: sampler.pixelWidth, height: sampler.pixelHeight)),
           let tile = sampler.smallImage(centeredAtPixelX: px.x, y: px.y, side: side) {
            ctx.interpolationQuality = .none
            ctx.draw(tile, in: box)
        } else {
            ctx.setFillColor(NSColor.darkGray.cgColor)
            ctx.fill(box)
        }
        ctx.restoreGState()

        // 2. 外圈（白+黑双层，深浅背景上都看得清）与中心十字
        ctx.saveGState()
        ctx.addPath(circle)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.addPath(circle)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: center.x - cell / 2, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + cell / 2, y: center.y))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: center.x, y: center.y - cell / 2))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + cell / 2))
        ctx.strokePath()
        ctx.restoreGState()

        // 3. 色值标签（HEX 与十进制都给出，方便贴到聊天里或设计稿里）
        guard let rgb = rgbAtCanvasPoint(cursor) else { return }
        let text = "\(ImagePixelSampler.hex(r: rgb.r, g: rgb.g, b: rgb.b))   "
            + ImagePixelSampler.rgbText(r: rgb.r, g: rgb.g, b: rgb.b)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let nsText = text as NSString
        let textSize = nsText.size(withAttributes: attrs)
        let swatch: CGFloat = textSize.height - 2

        var label = CGRect(x: 0, y: 0,
                           width: textSize.width + swatch + 20,
                           height: textSize.height + 8)
        label.origin = CGPoint(x: center.x - label.width / 2,
                               y: box.minY - label.height - 8)
        if label.minY < 4 {
            label.origin.y = box.maxY + 8          // 贴近底边时改画到上方
        }

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: label, cornerWidth: 6, cornerHeight: 6,
                           transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.76).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        let swatchRect = CGRect(x: label.minX + 6, y: label.midY - swatch / 2,
                                width: swatch, height: swatch)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: swatchRect, cornerWidth: 3, cornerHeight: 3,
                           transform: nil))
        ctx.setFillColor((pickerPreview ?? .black).cgColor)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: swatchRect, cornerWidth: 3, cornerHeight: 3,
                           transform: nil))
        ctx.strokePath()
        ctx.restoreGState()

        nsText.draw(at: CGPoint(x: swatchRect.maxX + 6, y: label.minY + 4),
                    withAttributes: attrs)
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

        // 6. 橡皮擦的笔刷圆环（悬停时也显示，让用户先看清作用范围再下笔）
        if currentTool == .eraser {
            drawEraseCursor(in: ctx)
        }

        // 7. 取色放大镜（同样在悬停时就显示，边移动边看色值）
        if currentTool == .picker {
            drawPickerLoupe(in: ctx)
        }

        // 8. 识别结果框（显示层，不参与导出）
        drawOCRHighlights(in: ctx)
    }

    /// 识别到的文字外框。画在最上层，颜色刻意和中性的选中框区分开。
    private func drawOCRHighlights(in ctx: CGContext) {
        guard !ocrHighlights.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemTeal.cgColor)
        ctx.setFillColor(NSColor.systemTeal.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 2])
        for rect in ocrHighlights {
            let path = CGPath(roundedRect: rect.insetBy(dx: -2, dy: -2),
                              cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
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
            sourceImage: baseCGImage,
            pixelScale: pixelScale,
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
