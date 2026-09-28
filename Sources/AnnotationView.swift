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
                // 把整幅 RGBA 副本还回去：pixelSampler 是"首次悬停即分配整张图"
                // （Retina 全屏可达 60MB+），不释放的话它会一直挂到关窗为止 ——
                // 用户只是路过一下取色器，却永久多占一份全屏位图。
                pixelSamplerStorage = nil
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
    /// 被动吸附的判定半径（点）：鼠标空闲移动时，离**吸附点**多近才亮起指示器。
    ///
    /// **它只管吸附点**（角点 / 中心，见各形状的 `snapPoints()`），
    /// **不管箭头端点到形状周长的附着** —— 后者是 `attachThreshold`（15）的事，
    /// 几何不同（点是离散的几个，附着是整条周长）、时机也不同（这个是空闲悬停的
    /// 指引，那个是落笔时的决定）。两个数**不要顺手统一**：
    ///   · 这个管"提示"：路过时给个视觉指引，宁小勿大（太大会到处亮）；
    ///   · 那个管"决定"：端点落下时是否记住附着关系，宁大勿小（记错了要手动挪开）。
    ///
    /// 把这两个数放在一起比大小是**看错了地方**：调大这个并不会让人看见"挂上了"，
    /// 因为附着从来就没有反馈。那件事由拖拽时的锚点预览（`draw(_:)` 第 4.5 步）
    /// 与选中时的锚点小环负责。这段注释是写给下一轮评审的。
    let snapThreshold: CGFloat = 12.0
    // 起始点是否吸附到了 snap point → 以该点为中心绘制
    private var drawingFromCenter: Bool = false

    // Undo/Redo 栈。非 private：撤销/重做已拆到 AnnotationView+UndoRedo.swift
    var undoStack: [UndoAction] = []
    var redoStack: [UndoAction] = []
    // 拖拽操作前的起始中心，用于计算总 delta
    private var dragStartCenter: CGPoint?
    // 移动箭头时会解除附着，这里记下解除前的状态供撤销使用
    private var pendingDetach: DetachedAttachments?
    private var rotateStartAngle: CGFloat = 0
    private var scaleStartFactor: CGFloat = 1

    // 调试面板：外部挂载的 NSImageView，用于实时显示 Layer B 可视化
    weak var debugImageView: NSImageView?

    // MARK: - 未送出的改动

    /// 画布内容的轻量指纹（几何 + 旋转 + 颜色 + 文字 + z 序）。
    ///
    /// 用"算出来的指纹"而不是"每次改动手动 +1"：后者要在十几个改动点各插一行，
    /// 漏掉任何一处都会让"有没有未送出的改动"判错 —— 而漏掉的后果是**关闭时不再提醒**，
    /// 正好是最不该出错的方向。指纹是纯计算结果，不存在漏插。
    var contentFingerprint: Int {
        var h = zOrder.count &* 1_000_003
        for key in zOrder {
            guard let o = objects[key] else { continue }
            h = h &* 31 &+ Int(key)
            h = h &* 31 &+ Int(o.center.x.rounded())
            h = h &* 31 &+ Int(o.center.y.rounded())
            h = h &* 31 &+ Int((o.rotation * 1000).rounded())
            h = h &* 31 &+ Int(o.boundingBox.width.rounded())
            h = h &* 31 &+ Int(o.boundingBox.height.rounded())
            if let c = o.color.usingColorSpace(.deviceRGB) {
                h = h &* 31 &+ Int((c.redComponent * 255).rounded())
                h = h &* 31 &+ Int((c.greenComponent * 255).rounded())
                h = h &* 31 &+ Int((c.blueComponent * 255).rounded())
            }
            if let t = o as? TextShape { h = h &* 31 &+ t.text.hashValue }
        }
        return h
    }

    /// 最近一次"内容已送出"（保存 / 复制 / 贴图）时的指纹；nil = 本次会话还没送出过
    private var exportedFingerprint: Int?

    /// 是否还有**未送出的、且确实存在于画布上的**标注。
    /// 关窗 / 放弃截图前用它决定要不要弹确认。
    ///
    /// 不用 `!undoStack.isEmpty`：画完又全部删掉、或刚导出过没再改，
    /// 这两种情况画布上都没什么可丢的，却会白弹一次确认框。
    var hasUnsavedAnnotations: Bool {
        guard !objects.isEmpty else { return false }
        return contentFingerprint != exportedFingerprint
    }

    /// 标记"当前内容已经被送出去了"（保存 / 复制 / 贴图都会走到 compositeImage）
    func markContentExported() {
        exportedFingerprint = contentFingerprint
    }

    // MARK: - 改选中对象的样式

    /// 对象当前的线宽；不支持线宽的对象（贴纸 / 文字 / 聚光灯）返回 nil
    static func lineWidth(of obj: any AnnotationObject) -> CGFloat? {
        if let arrow = obj as? Arrow { return arrow.lineWidth }
        if let rect = obj as? RectangleShape { return rect.lineWidth }
        if let circle = obj as? CircleShape { return circle.lineWidth }
        return nil
    }

    static func setLineWidth(_ value: CGFloat, on obj: any AnnotationObject) {
        if let arrow = obj as? Arrow { arrow.lineWidth = value }
        else if let rect = obj as? RectangleShape { rect.lineWidth = value }
        else if let circle = obj as? CircleShape { circle.lineWidth = value }
    }

    /// 颜色是否视为同一个（动态系统色直接 `==` 会误判，统一折到 deviceRGB 比）
    private static func colorsEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.deviceRGB),
              let y = b.usingColorSpace(.deviceRGB) else { return a == b }
        return abs(x.redComponent - y.redComponent) < 0.002
            && abs(x.greenComponent - y.greenComponent) < 0.002
            && abs(x.blueComponent - y.blueComponent) < 0.002
            && abs(x.alphaComponent - y.alphaComponent) < 0.002
    }

    /// 选中对象的颜色（无选中时为 nil）
    var selectedObjectColor: NSColor? {
        guard let key = selectedKey, let obj = objects[key] else { return nil }
        return obj.color
    }

    /// 选中对象的线宽（无选中 / 该类型没有线宽时为 nil）
    var selectedObjectLineWidth: CGFloat? {
        guard let key = selectedKey, let obj = objects[key] else { return nil }
        return Self.lineWidth(of: obj)
    }

    /// 把**选中对象**的样式改成给定值（可撤销）。返回是否真的发生了变化。
    ///
    /// 与 `currentColor` / `currentLineWidth` 的区别：那两个只影响**之后新画**的对象，
    /// 这里改的是已经画好、且当前被选中的那一个 —— 用户选中一个箭头再点色点，
    /// 期望的是"把这一个改掉"，而不是"下一个画出来是什么颜色"。
    @discardableResult
    func restyleSelection(color newColor: NSColor? = nil, lineWidth newLineWidth: CGFloat? = nil) -> Bool {
        guard let key = selectedKey, let obj = objects[key] else { return false }

        let oldColor = obj.color
        let oldLineWidth = Self.lineWidth(of: obj)

        var changed = false
        if let color = newColor, !Self.colorsEqual(color, obj.color) {
            obj.color = color
            changed = true
        }
        if let width = newLineWidth, let current = oldLineWidth, abs(current - width) > 0.01 {
            Self.setLineWidth(width, on: obj)
            changed = true
        }
        guard changed else { return false }

        undoStack.append(.restyle(colorKey: key,
                                  oldColor: oldColor, newColor: obj.color,
                                  oldLineWidth: oldLineWidth,
                                  newLineWidth: Self.lineWidth(of: obj)))
        redoStack.removeAll()
        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
        needsDisplay = true
        return true
    }

    // MARK: - 连续改样式（滑杆拖拽）

    /// 一次连续调整开始时的样式快照（`nil` = 当时没有选中对象）
    private var continuousRestyleBaseline: (color: NSColor, lineWidth: CGFloat?)?

    /// 连续调整开始：记下起点样式，供结束时合成**一条**撤销记录。
    ///
    /// 为什么需要它：`NSSlider` 连续发 action，一次拖拽几十次。若每次都记一条撤销，
    /// 用户按 ⌘Z 只会退回 0.24px 的一小步 —— 从 30 退回 15 得按几十次
    /// （实测 37 次 action → 37 条撤销记录）。
    func beginContinuousRestyle() {
        guard let key = selectedKey, let obj = objects[key] else {
            continuousRestyleBaseline = nil
            return
        }
        continuousRestyleBaseline = (obj.color, Self.lineWidth(of: obj))
    }

    /// 拖拽过程中实时改，但**不**记撤销。
    ///
    /// 刻意不重绘命中层：拖拽期间用户不会去点画布，而整张 Layer B 重绘是 MB 级
    /// 工作量，每帧做一次会卡。`endContinuousRestyle` 会补上那一次。
    func updateContinuousRestyle(lineWidth newLineWidth: CGFloat) {
        guard let key = selectedKey, let obj = objects[key],
              let current = Self.lineWidth(of: obj),
              abs(current - newLineWidth) > 0.01 else { return }
        Self.setLineWidth(newLineWidth, on: obj)
        needsDisplay = true
    }

    /// 连续调整结束：把"起点 → 终点"合成一条撤销记录。
    func endContinuousRestyle() {
        defer { continuousRestyleBaseline = nil }
        guard let key = selectedKey, let obj = objects[key],
              let baseline = continuousRestyleBaseline else { return }
        let newLineWidth = Self.lineWidth(of: obj)
        // 转了一圈又回到原值就不记 —— 撤销栈里不该出现"什么也没变"的一步
        guard baseline.lineWidth != newLineWidth else { return }

        undoStack.append(.restyle(colorKey: key,
                                  oldColor: baseline.color, newColor: obj.color,
                                  oldLineWidth: baseline.lineWidth,
                                  newLineWidth: newLineWidth))
        redoStack.removeAll()
        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)   // 拖拽期间省下的那一次
        refreshDebugView()
        needsDisplay = true
    }

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
    // MARK: - 命中层脏标记

    /// 命中层自上次重绘以来是否已经过期。
    ///
    /// 移动/旋转/缩放期间对象一直在动，命中层里「谁画在哪个像素上」也就一直在变。
    /// 原来每个鼠标事件都全量重绘一次 Layer B（整幅画布，Retina 全屏 15MB+），
    /// 而**拖拽过程中根本没人读它** —— 真正读它的只有"按下鼠标找对象"与
    /// "橡皮擦连续采样"。
    ///
    /// 改成脏标记 + **读前补绘**：拖拽期间只记一笔，谁要读谁先 flush。
    /// 这样"忘了重绘"在构造上不可能发生 —— 消费点自己负责先补。
    private var hitLayerDirty = false

    /// 读命中层之前，把拖拽期间欠下的那次重绘补上
    private func flushHitLayerIfNeeded() {
        guard hitLayerDirty else { return }
        hitLayerDirty = false
        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
    }

    /// 整幅 RGBA 副本，供取色器采样。**切走取色器时置回 nil**（见 `currentTool.didSet`）——
    /// 它按需分配但不自动释放，不清的话用户路过一次取色器就永久多占一份全屏位图。
    ///
    /// 不能写成 `lazy var`：`lazy` 只在**首次读取**时初始化，一旦被赋过值（包括赋 nil）
    /// 就永远不会再初始化 —— 那样释放一次之后取色器就永久失效了。所以用「可空的存储 +
    /// 按需装载」的写法。
    private var pixelSamplerStorage: ImagePixelSampler?

    /// 取色器采样器：第一次用到时才分配，切走取色器时被释放，之后再用到会重新分配。
    private func pickerSampler() -> ImagePixelSampler? {
        if let cached = pixelSamplerStorage { return cached }
        let made = baseCGImage.flatMap { ImagePixelSampler(image: $0) }
        pixelSamplerStorage = made
        return made
    }

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

    /// 源截图的**像素**尺寸。导出时以此为准。
    ///
    /// 不传的话就只能靠 `NSImage.lockFocus()` 让系统按"当前显示器"决定分辨率 ——
    /// 在 1x 外接屏上标注 2x 截图，导出的 PNG 会掉一半像素。
    private let sourcePixelSize: CGSize?

    init(image: NSImage, pixelSize: CGSize? = nil) {
        self.baseImage = image
        self.sourcePixelSize = pixelSize
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
            // 只在吸附点**真的变了**的时候置脏。
            //
            // 原来无条件 `needsDisplay = true`：鼠标在画布上随便移动都触发整幅重绘
            // （draw(_:) 不按 dirtyRect 裁剪），而绝大多数位置根本没有吸附点 ——
            // 等于为了一个没变化的指示器，把整张画布连同底图重画一遍。
            let newSnap = findNearestSnapPoint(to: point, excludeKey: nil)?.point
            if newSnap != activeSnapPoint {
                activeSnapPoint = newSnap
                needsDisplay = true
            }
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
            let deleteCenter = AnnotationView.deleteButtonCenter(for: selRect,
                                                                deleteSize: deleteSize)
            let distToDelete = hypot(point.x - deleteCenter.x, point.y - deleteCenter.y)
            if distToDelete <= deleteSize / 2 + 4 {
                // 与 Delete 键、菜单「删除选中」走同一条路（原先这里是一份复制粘贴的
                // 实现，三处各自维护"收集级联箭头 + 记撤销 + 重绘"迟早会漏掉一步）
                deleteSelectedObject()
                return
            }
        }

        // 已选中对象时，修饰键触发旋转/缩放。
        // **必须要求按下的位置落在该对象上**：否则在画布空白处按 Option/Shift 拖拽
        // 会莫名其妙地改动一个远处的对象，而用户的本意是"画个新图形"。
        // 不满足时**不 return**，继续往下走正常的命中/绘制流程。
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

        // 在 Layer B 上查找鼠标位置的颜色（拖拽刚结束的话，先把它欠的重绘补上）
        flushHitLayerIfNeeded()
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
            // 记下拖拽前的附着关系：真正发生移动时会被解除，撤销要靠它还原
            if let arrow = obj as? Arrow {
                pendingDetach = DetachedAttachments(key: colorKey,
                                                    start: arrow.startAttachment,
                                                    end: arrow.endAttachment)
            } else {
                pendingDetach = nil
            }
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

            // 注意：**这里不解除箭头附着**。
            // 解除动作推迟到 mouseUp —— 只有确认这是一次"会被记账的真实移动"时才解。
            // 否则 2x 屏上 1 物理像素（0.5pt）的手抖就会解除附着，
            // 而 mouseUp 的记账阈值是"严格大于 0.5pt"，于是附着被清空却没有任何撤销记录。
            // 如果移动的是形状，更新附着的箭头端点
            updateAttachedArrows(forParent: colorKey)

            // 重绘 Layer B
            hitLayerDirty = true   // 拖拽期间不重绘，读命中层前统一补（见 flushHitLayerIfNeeded）
            refreshDebugView()
            needsDisplay = true

        case .rotating(let colorKey, let lastAngle):
            guard let obj = objects[colorKey] else { return }
            let currentAngle = atan2(point.y - obj.center.y, point.x - obj.center.x)
            let deltaAngle = currentAngle - lastAngle
            obj.rotate(by: deltaAngle)
            rotateStartAngle += deltaAngle
            state = .rotating(colorKey: colorKey, lastAngle: currentAngle)

            hitLayerDirty = true   // 拖拽期间不重绘，读命中层前统一补（见 flushHitLayerIfNeeded）
            refreshDebugView()
            needsDisplay = true

        case .scaling(let colorKey, let lastDistance):
            guard let obj = objects[colorKey] else { return }
            let currentDist = hypot(point.x - obj.center.x, point.y - obj.center.y)
            if currentDist > 1 && lastDistance > 1 {
                let factor = currentDist / lastDistance
                // 缩放下限由**各形状自己的 scale** 负责 —— 它才知道自己的本体尺寸。
                // 包围盒含线宽/箭头头部这些绘制外扩，原来拿它判"最小 5pt"时形状本体
                // 可以一路缩到 0（包围盒仍有几十点），于是对象变成看不见的一点。
                // 这里只留一道"别缩成真正的零"的兜底。
                let box = obj.boundingBox
                let minDim = min(box.width, box.height)
                if minDim * factor > 0.5 || factor >= 1 {
                    obj.scale(by: factor)
                    scaleStartFactor *= factor
                    state = .scaling(colorKey: colorKey, lastDistance: currentDist)
                }
            }

            hitLayerDirty = true   // 拖拽期间不重绘，读命中层前统一补（见 flushHitLayerIfNeeded）
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
                    // 确认是一次真实移动 → 此时才解除附着，并把"解除前的状态"一并记账
                    if let arrow = obj as? Arrow {
                        arrow.startAttachment = nil
                        arrow.endAttachment = nil
                    }
                    undoStack.append(.move(colorKey: colorKey, delta: totalDelta,
                                           detached: pendingDetach))
                    redoStack.removeAll()
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
            } else if rotateStartAngle != 0, let obj = objects[colorKey] {
                // 同理：没记账就把旋转回退掉
                obj.rotate(by: -rotateStartAngle)
                updateAttachedArrows(forParent: colorKey)
                hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
                refreshDebugView()
            }
            rotateStartAngle = 0

        case .scaling(let colorKey, _):
            if abs(scaleStartFactor - 1) > 0.001 {
                undoStack.append(.scale(colorKey: colorKey, factor: scaleStartFactor))
                redoStack.removeAll()
            } else if scaleStartFactor != 1, let obj = objects[colorKey] {
                obj.scale(by: 1.0 / scaleStartFactor)
                updateAttachedArrows(forParent: colorKey)
                hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
                refreshDebugView()
            }
            scaleStartFactor = 1

        case .erasing:
            // 整笔拖拽合并成一步撤销：否则按一次 ⌘Z 只退回一个对象，
            // 想退回原状得按十几次 —— 那等于撤销功能对橡皮擦不可用。
            if !eraseDeleted.isEmpty {
                undoStack.append(.delete(objects: eraseDeleted,
                                         zOrderBefore: eraseZOrderBefore,
                                         zOrderAfter: zOrder))
                redoStack.removeAll()
                renumberStepBadges()
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
            // 变换进行中先把它**回退**掉。此刻手势还没走到 mouseUp，
            // 若只是把 state 清成 .idle，mouseUp 就会落进 .idle 分支 ——
            // 半途的位移 / 旋转 / 缩放被留下却没有任何撤销记录，无法挽回。
            cancelActiveGesture()
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

        // 符号/数字键直选工具。用**字符**而不是 keyCode：主键盘与数字小键的
        // keyCode 不同，字符才是统一的。
        //   1–9 → 前 9 个；0 / - / = → 第 10 / 11 / 12 个（模糊 / 橡皮 / 取色）
        // 工具已有 12 个，只留 1–9 会让后 3 个无法直选（旧账：数字键只到 9）。
        if let chars = event.charactersIgnoringModifiers {
            let index: Int?
            switch chars {
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                index = (Int(chars) ?? 1) - 1
            case "0":
                index = 9
            case "-":
                index = 10
            case "=":
                index = 11
            default:
                index = nil
            }
            if let index {
                (window as? AnnotationWindow)?.selectTool(atIndex: index)
                return true
            }
        }

        return false
    }

    /// 把进行中的移动 / 旋转 / 缩放 / 橡皮擦**回退**掉，并归还在拖拽期间被解除的附着关系。
    ///
    /// 只在手势被意外中断时调用（目前是 Esc）。正常路径由 mouseUp 负责记账、
    /// 不经过这里 —— 它存在的意义是维持"画布变了就一定有撤销记录"这个不变量。
    private func cancelActiveGesture() {
        switch state {
        case .moving(let colorKey, _):
            if let obj = objects[colorKey], let start = dragStartCenter {
                let delta = CGVector(dx: obj.center.x - start.x, dy: obj.center.y - start.y)
                if delta.dx != 0 || delta.dy != 0 {
                    obj.move(by: CGVector(dx: -delta.dx, dy: -delta.dy))
                }
                restoreDetachedAttachments(pendingDetach)
                updateAttachedArrows(forParent: colorKey)
            }
            dragStartCenter = nil
            pendingDetach = nil

        case .rotating(let colorKey, _):
            if let obj = objects[colorKey], rotateStartAngle != 0 {
                obj.rotate(by: -rotateStartAngle)
                updateAttachedArrows(forParent: colorKey)
            }
            rotateStartAngle = 0

        case .scaling(let colorKey, _):
            if let obj = objects[colorKey], scaleStartFactor != 1, scaleStartFactor != 0 {
                obj.scale(by: 1.0 / scaleStartFactor)
                updateAttachedArrows(forParent: colorKey)
            }
            scaleStartFactor = 1

        case .erasing:
            // 橡皮擦在**拖拽途中就已经真删了**对象（见 erase(at:)），而 Esc 会把 state
            // 置成 .idle，于是 mouseUp 落进 .idle 分支 —— 这一笔既不入撤销栈，
            // 也无法 ⌘Z 找回，等于凭空丢标注。Esc 的语义是"取消"，那就真的取消。
            restoreEraseStroke()

        default:
            return      // idle / drawing / picking：没有需要回退的改动
        }

        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
        needsDisplay = true
    }

    /// 把本笔橡皮擦已经摘掉的对象放回画布。
    ///
    /// `eraseDeleted` 里是 `takeOutOfCanvas` 的完整产出，**包含随父对象一起被摘掉的箭头**，
    /// 所以直接放回 + 还原 z 序即可（与 `performUndo` 的 `.delete` 分支同一套做法）。
    /// 不碰 `eraseCursor`：那个圆环是按 `currentTool == .eraser` 门控的悬停指示器，
    /// 不属于笔画状态。
    private func restoreEraseStroke() {
        guard !eraseDeleted.isEmpty else {
            eraseZOrderBefore = []
            lastErasePoint = nil
            return
        }
        for (key, obj) in eraseDeleted {
            objects[key] = obj
        }
        zOrder = eraseZOrderBefore
        eraseDeleted = []
        eraseZOrderBefore = []
        lastErasePoint = nil
        renumberStepBadges()
    }

    /// 撤销"移动箭头"时，把当初被解除的附着关系装回去（并把端点吸回父对象周长）
    func restoreDetachedAttachments(_ snapshot: DetachedAttachments?) {
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

    /// 删除当前选中的对象（含挂在它上面的箭头），并记录一步撤销。
    ///
    /// 抽成方法是因为它有多个入口：Delete 键、菜单的「删除选中」、以及选中框右上角的叉号。
    func deleteSelectedObject() {
        guard let key = selectedKey else { return }

        let zOrderBefore = zOrder
        let taken = takeOutOfCanvas(key)
        guard !taken.isEmpty else { return }

        undoStack.append(.delete(objects: taken,
                                 zOrderBefore: zOrderBefore,
                                 zOrderAfter: zOrder))
        redoStack.removeAll()
        renumberStepBadges()
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
        flushHitLayerIfNeeded()
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
        guard let sampler = pickerSampler(),
              let px = ImagePixelSampler.pixelCoordinate(
                canvasPoint: point,
                canvasSize: baseImage.size,
                pixelSize: CGSize(width: sampler.pixelWidth,
                                  height: sampler.pixelHeight)) else { return nil }
        return sampler.rgb(atPixelX: px.x, y: px.y)
    }

    /// 取色放大镜 + 色值标签。
    private func drawPickerLoupe(in ctx: CGContext) {
        guard let cursor = pickerPoint, let sampler = pickerSampler() else { return }

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
    /// 创建瞬间先取 max+1（避免与还留在画布上的编号撞号）；
    /// 随后 `renumberStepBadges()` 会按 z 序收成 1..n，所以「可重排」
    /// （删中间一个后其余续上）由重编号保证，不靠这里的分配策略。
    private func nextStepNumber() -> Int {
        var maxNumber = 0
        for (_, object) in objects {
            if let badge = object as? StepBadge {
                maxNumber = max(maxNumber, badge.number)
            }
        }
        return maxNumber + 1
    }

    /// 把画布上的序号标注按 z 序（底→顶，近似放置顺序）重新编成 1..n。
    ///
    /// 路线图 P0-B6 要求「自动递增 **+ 可重排**」：删掉中间的 2 之后，
    /// 剩下的应变成 1、2，而不是 1、3。编号只是显示状态，**不进撤销栈** ——
    /// 撤销恢复的是对象与 z 序，随后同样重编号，结果自然正确。
    func renumberStepBadges() {
        var n = 0
        var changed = false
        for key in zOrder {
            guard let badge = objects[key] as? StepBadge else { continue }
            n += 1
            if badge.number != n {
                badge.number = n
                changed = true
            }
        }
        // 只有数字变了才需要重绘；命中层不画数字，不必动 Layer B
        if changed {
            needsDisplay = true
        }
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

        // 4.5 拖拽箭头时：如果**松手会附着到某个形状上**，先把锚点标出来
        //
        // 附着是个"看不见的状态"：落笔那一刻它悄悄记下了关系，之后要么父对象移动时
        // 箭头跟着走、要么父对象被删时箭头一起消失 —— 用户要到那时才知道。
        //
        // 注意：第 5 步的吸附指示器画的是**吸附点**（角点/中心），与"周长附着"是两套
        // 东西。所以"把 snapThreshold 调大一点"并不能让人看见附着 —— 附着在任何距离
        // 都没有反馈（3 或 14 都一样）。上一轮评审曾把这两件事混起来，这里一并说清。
        if case .drawing(let tool, _) = state, tool == .arrow, let end = currentDrawEnd,
           let attachment = detectAttachment(at: end, excludeKey: nil),
           let anchor = resolveAttachmentPosition(attachment) {
            drawAttachRing(at: anchor, in: ctx)
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
        let zOrderBefore = zOrder
        objects[colorKey] = obj
        zOrder.append(colorKey)
        undoStack.append(.add(objects: [(colorKey, obj)],
                              zOrderBefore: zOrderBefore,
                              zOrderAfter: zOrder))
        redoStack.removeAll()
        hitTestBuffer.drawObject(obj)
        renumberStepBadges()
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

    /// 选中框右上角那个删除按钮的中心。
    ///
    /// **命中判定与绘制必须用同一个公式**：原来这一行在
    /// `AnnotationView`（判命中）与 `AnnotationView+Rendering`（画按钮）里各写了一遍，
    /// 改一处就是"看得见的按钮点不中"或"点到看不见的地方"，而且不会有任何报错。
    static func deleteButtonCenter(for selectionRect: CGRect, deleteSize: CGFloat) -> CGPoint {
        CGPoint(x: selectionRect.maxX + deleteSize * 0.3,
                y: selectionRect.maxY + deleteSize * 0.3)
    }

    /// 刷新右侧的 Layer B 调试面板。非 private：撤销/重做扩展要用
    ///
    /// **面板隐藏时直接返回**：它默认隐藏（⌘D 才显示），但视图一直挂在窗口上，
    /// 原来只判 `!= nil` —— 于是拖拽时每个鼠标事件都照样跑一遍 `debugVisualization`
    /// （全对象 drawHitTest + `makeImage()` 拷一份整幅位图），面板没开也要付这个成本。
    /// 显示时由 `AnnotationWindow.toggleDebugPanel` 补一次刷新。
    func refreshDebugView() {
        guard let imageView = debugImageView, !imageView.isHidden else { return }
        flushHitLayerIfNeeded()
        let debugImage = hitTestBuffer.debugVisualization(objects: objects, zOrder: zOrder)
        imageView.image = debugImage
    }

    // MARK: - Export

    /// 导出用的像素尺寸：优先用调用方显式传入的源图像素尺寸，
    /// 否则从 `baseImage` 的 representation 里取最大的那个
    /// （`NSImage(cgImage:size:)` 的 rep 往往报不出可靠像素数，所以显式传入才是正路）。
    private var exportPixelSize: CGSize {
        if let explicit = sourcePixelSize, explicit.width >= 1, explicit.height >= 1 {
            return explicit
        }
        let rep = baseImage.representations
            .filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        if let rep = rep {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        // 最后兜底：从**已解码的 CGImage** 反推像素尺寸，而不是假定 2×。
        //
        // 整个项目都在"实测反推倍率、不假定 backingScaleFactor"（见 CapturedImage），
        // 这里写死 ×2 与那条原则自相矛盾：1x 屏上会凭空放大一倍、3x 屏上又少一截。
        if let cg = baseCGImage, cg.width > 0, cg.height > 0 {
            return CGSize(width: cg.width, height: cg.height)
        }
        // 连 CGImage 都拿不到（理论上不可达）：退回点尺寸 —— 宁可 1×，也不要凭空的 2×
        return baseImage.size
    }

    /// 生成最终合成图片（底图 + 所有标注对象）
    func compositeImage() -> NSImage {
        // 保存 / 复制 / 贴图都会走这里 —— 内容既然已经送出去，之后关窗就不必再提醒
        markContentExported()

        let pointSize = baseImage.size
        let pixels = exportPixelSize
        // 两个方向各算一次、分别施加。
        //
        // 当前 `logicalSize` 是按**同一个** pixelScale 从像素尺寸推出来的
        // （见 CapturedImage.logicalSize），所以两个比值恒等、取哪个都一样 ——
        // 但只按宽度算是个隐式假设：万一将来 logicalSize 的来源变了（例如某条路
        // 传进来的点尺寸与像素不同源），图就会被拉变形且没人会发现。分开写没有代价。
        let scaleX = max(pixels.width / max(pointSize.width, 1), 0.01)
        let scaleY = max(pixels.height / max(pointSize.height, 1), 0.01)

        // 用**显式位图**而不是 `NSImage.lockFocus()`：
        // lockFocus 的分辨率取决于"当前显示器"的 backingScaleFactor ——
        // 在 1x 外接屏上标注 2x 截图，导出的 PNG 会掉一半像素（在 2x 屏上则碰巧正确，
        // 所以这个 bug 只在换显示器时才暴露）。这里按源图**像素**尺寸建上下文，
        // 之后照常按"点"坐标绘制，由 scaleBy 放大到像素。
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: max(Int(pixels.width), 1),
                                         pixelsHigh: max(Int(pixels.height), 1),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return compositeViaLockFocus(pointSize: pointSize)   // 兜底，正常不会走到
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scaleX, y: scaleY)
            render(into: ctx, pointSize: pointSize)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    /// 建不出显式位图时的兜底路径（分辨率随当前显示器，仅用于不中断导出）
    private func compositeViaLockFocus(pointSize: NSSize) -> NSImage {
        let image = NSImage(size: pointSize)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            render(into: ctx, pointSize: pointSize)
        }
        image.unlockFocus()
        return image
    }

    /// 把底图、聚光灯遮罩、所有对象、水印渲染进给定上下文（坐标是"点"）
    private func render(into ctx: CGContext, pointSize: NSSize) {
        let rect = CGRect(origin: .zero, size: pointSize)
        baseImage.draw(in: rect)
        // Spotlight 遮罩
        drawSpotlightOverlay(in: ctx)
        for key in zOrder {
            if let obj = objects[key] {
                // 用 drawForExport 而不是 draw：聚光灯的虚线边框是编辑器 UI，
                // 不该出现在导出图里（其余类型默认行为与 draw 相同）
                obj.drawForExport(in: ctx)
            }
        }
        // 水印（最后绘制，覆盖在所有内容之上）
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
