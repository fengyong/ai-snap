import Cocoa

// A 区修复在 master 上的对齐验证。
//
// 背景：A、B 是同一条 master 的两个分叉。逐项审计后发现 A 修过的若干问题
// 在 master 上**仍然存在**（不是"旧代码不需要"，是真的缺）。这个探针守住
// 在 master 上重新实现的那几项。
//
// 断言全部锚在**可观察后果**上：能读像素就读像素，能驱动真实鼠标事件就驱动，
// 不满足于"函数返回了某个值"—— 那样的断言在本项目里已经被证明会漏掉真问题
// （windowShouldClose 写了但没接 delegate，函数存在、调用却永远不来）。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
}

_ = NSApplication.shared

func blankCanvas(_ w: CGFloat, _ h: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    image.unlockFocus()
    return image
}

func mouse(_ type: NSEvent.EventType, _ p: CGPoint,
           _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0,
                       clickCount: 1, pressure: 1)!
}

/// 扫描图像里"非白像素"的最右 x（用来量箭头有没有越过尖端）
func rightmostInk(_ image: NSImage, yBand: ClosedRange<Int>) -> Int {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return -1 }
    var best = -1
    for y in yBand {
        guard y >= 0, y < rep.pixelsHigh else { continue }
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97 {
                best = max(best, x)
            }
        }
    }
    return best
}

/// 扫描图像里"非白像素"的最左 x（用来量箭杆有没有画到起点左边去）
func leftmostInk(_ rep: NSBitmapImageRep) -> Int {
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97 {
                return x
            }
        }
    }
    return -1
}

// MARK: - 1. 箭头头部必须随线宽缩放

print("=== 1. 箭头头部随线宽缩放（固定 14pt 在默认线宽下没有头）===")
do {
    let standard = ArrowStyle.default
    let spread = standard.headAngle

    // 硬性要求：三角头的全宽（2·len·sin(spread)）必须**明显宽于**箭杆
    var allWider = true
    var worst = ""
    for lw: CGFloat in [1, 3, 8, 15, 26, 40] {
        let len = Arrow.headLength(for: standard, lineWidth: lw)
        let headWidth = 2 * len * sin(spread)
        if headWidth <= lw * 1.5 {
            allWider = false
            worst = String(format: "线宽 %.0f 时头宽仅 %.0f", lw, headWidth)
        }
    }
    check("各线宽下三角头都明显宽于箭杆", allWider,
          worst.isEmpty ? "1/3/8/15/26/40 全部满足" : worst)

    check("细线宽下仍用样式自带的 headLength（不被缩放压小）",
          Arrow.headLength(for: standard, lineWidth: 3) == standard.headLength,
          "\(Arrow.headLength(for: standard, lineWidth: 3))")
    check("默认线宽 15 时头部被放大",
          Arrow.headLength(for: standard, lineWidth: 15) > standard.headLength,
          "\(Arrow.headLength(for: standard, lineWidth: 15)) vs \(standard.headLength)")

    // 像素实测：默认 15px 线宽画一根水平箭头，头部区域的竖直展开必须宽于箭杆
    let view = AnnotationView(image: blankCanvas(400, 200))
    let key = view.hitTestBuffer.generateUniqueColorKey()
    let arrow = Arrow(startPoint: CGPoint(x: 60, y: 100), endPoint: CGPoint(x: 300, y: 100),
                      color: .black, lineWidth: 15, hitTestColorKey: key)
    view.objects[key] = arrow
    view.zOrder = [key]

    guard let rep = NSBitmapImageRep(data: view.compositeImage().tiffRepresentation!) else {
        check("能读到合成图", false); exit(1)
    }
    func inkHeight(atX x: Int) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            if let c = rep.colorAt(x: x, y: y),
               c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97 {
                n += 1
            }
        }
        return n
    }
    /// 整幅图里最高的那一列墨迹 —— 箭头最宽处（三角头底边）
    func maxInkHeight() -> Int {
        var best = 0
        for x in 0..<rep.pixelsWide { best = max(best, inkHeight(atX: x)) }
        return best
    }

    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let shaftH = inkHeight(atX: Int(150 * scale))       // 箭杆中段
    let widestH = maxInkHeight()                        // 含三角头
    // 旧实现：headLength 固定 14 → 头宽 2·14·sin30° = 14pt < 箭杆 15pt，
    // 于是"最宽处"就是箭杆本身；修复后头宽 = lineWidth·3.2 = 48pt，明显更宽。
    check("像素实测：最宽处（头部）明显宽于箭杆", widestH > shaftH + 5,
          "箭杆高 \(shaftH)px，最宽处 \(widestH)px")
}

// MARK: - 2. 箭杆终点：实心头收住、开放头到尖端

print("\n=== 2. 箭杆终点分情况（实心头收住 / 开放头到尖端）===")
do {
    func tipInk(_ style: ArrowStyle, _ label: String) -> Int {
        let view = AnnotationView(image: blankCanvas(400, 200))
        let key = view.hitTestBuffer.generateUniqueColorKey()
        view.objects[key] = Arrow(startPoint: CGPoint(x: 60, y: 100),
                                  endPoint: CGPoint(x: 300, y: 100),
                                  color: .black, lineWidth: 15,
                                  hitTestColorKey: key, style: style)
        view.zOrder = [key]
        let composite = view.compositeImage()
        guard let tiff = composite.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        let band = (rep.pixelsHigh / 2 - 40)...(rep.pixelsHigh / 2 + 40)
        let got = rightmostInk(composite, yBand: band)
        print(String(format: "     %@：最右墨迹 x=%d（尖端 x=%d）", label, got,
                     Int(300 * CGFloat(rep.pixelsWide) / view.bounds.width)))
        return got
    }

    // 2x 屏上 300pt = 600px；探针按实际像素倍率判断，这里用比值容差
    guard let probeRep = NSBitmapImageRep(
            data: AnnotationView(image: blankCanvas(400, 200)).compositeImage().tiffRepresentation!)
    else { check("能读到合成图", false); exit(1) }
    let scale = CGFloat(probeRep.pixelsWide) / 400
    let tipPx = Int(300 * scale)

    let solid = tipInk(.default, "实心三角头")
    let open = tipInk(.openArrow, "开放头")

    // 实心：箭杆提前收住，圆头端帽不该越过三角形尖端
    // 旧实现在这里会多出 半个线宽（线宽 15 → 约 15px@2x）的圆头凸起
    check("实心头：没有任何东西越过尖端", solid <= tipPx + 4,
          "实心头最右 \(solid)，尖端 \(tipPx)")
    // 开放：箭杆必须画到尖端，否则两条头线之间会有断口
    check("开放头：箭杆画到了尖端", open >= tipPx - 4,
          "开放头最右 \(open)，尖端 \(tipPx)")

    // ── 短箭头：箭杆回缩量不得把箭杆推到起点反方向 ──────────────────────
    //
    // 头部长度随线宽放大后能到 48pt（线宽 15），比短箭头的整根箭杆还长。
    // 回缩量若不设上限，`endPoint - 回缩量` 就落到起点**反方向**去，箭杆
    // 倒着画出来，在箭头后面露出一截圆头 —— 修复前实测比几何容许的最左
    // 位置多出 7.4px。这里同时放一个长箭头做**对照组**：少了它，一个
    // "干脆不画箭杆"的假修复也能让短箭头那条断言通过。
    func arrowLeftmost(startX: CGFloat, tipX: CGFloat) -> (left: Int, pxPerPoint: CGFloat) {
        let view = AnnotationView(image: blankCanvas(500, 220))
        let key = view.hitTestBuffer.generateUniqueColorKey()
        view.objects[key] = Arrow(startPoint: CGPoint(x: startX, y: 110),
                                  endPoint: CGPoint(x: tipX, y: 110),
                                  color: .black, lineWidth: 15,
                                  hitTestColorKey: key, style: .default)
        view.zOrder = [key]
        let composite = view.compositeImage()
        guard let rep = NSBitmapImageRep(data: composite.tiffRepresentation ?? Data()) else {
            return (-1, 1)
        }
        return (leftmostInk(rep), CGFloat(rep.pixelsWide) / max(view.bounds.width, 1))
    }

    let headLenPx = Arrow.headLength(for: .default, lineWidth: 15)
    let spread = ArrowStyle.default.headAngle
    let short = arrowLeftmost(startX: 250, tipX: 270)
    let shortAllowed = min(250 - 15 / 2, 270 - headLenPx * cos(spread)) * short.pxPerPoint
    check("短箭头：箭杆不得画到起点反方向（整根藏在头部里就不画）",
          CGFloat(short.left) >= shortAllowed - 1.5,
          String(format: "最左 %d，几何容许 %.1f", short.left, shortAllowed))

    let longArrow = arrowLeftmost(startX: 50, tipX: 400)
    let longAllowed = (50 - 15 / 2) * longArrow.pxPerPoint
    check("长箭头（对照）：箭杆仍从起点圆帽起画，没有被整根删掉",
          abs(CGFloat(longArrow.left) - longAllowed) <= 2,
          String(format: "最左 %d，起点圆帽 %.1f", longArrow.left, longAllowed))
}

// MARK: - 3. Option/Shift 只在按到对象上时才旋转/缩放

print("\n=== 3. Option/Shift 必须按在对象上（空白处拖拽不再误改选中对象）===")
do {
    func makeSelectedRect() -> (AnnotationView, UInt32) {
        let view = AnnotationView(image: blankCanvas(600, 400))
        let key = view.hitTestBuffer.generateUniqueColorKey()
        let rect = RectangleShape(from: CGPoint(x: 100, y: 100),
                                  to: CGPoint(x: 220, y: 200),
                                  color: .black, lineWidth: 15, hitTestColorKey: key)
        view.objects[key] = rect
        view.zOrder = [key]
        view.hitTestBuffer.drawObject(rect)
        // 点一下对象把它选中（真实事件路径）
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 160, y: 100)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 160, y: 100)))
        return (view, key)
    }

    // A) 空白处 Option 拖拽 → 不该动那个对象
    let (v1, k1) = makeSelectedRect()
    let rotBefore = (v1.objects[k1] as? RectangleShape)?.rotation ?? -99
    v1.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 480, y: 330), .option))
    v1.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 540, y: 360), .option))
    v1.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 540, y: 360), .option))
    let rotAfter = (v1.objects[k1] as? RectangleShape)?.rotation ?? -99
    check("空白处 Option 拖拽不旋转对象", abs(rotAfter - rotBefore) < 0.001,
          "rotation \(rotBefore) → \(rotAfter)")

    // B) 对照：按在对象上 Option 拖拽 → 应该旋转
    let (v2, k2) = makeSelectedRect()
    let rot2Before = (v2.objects[k2] as? RectangleShape)?.rotation ?? -99
    v2.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 160, y: 100), .option))
    v2.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 230, y: 160), .option))
    v2.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 230, y: 160), .option))
    let rot2After = (v2.objects[k2] as? RectangleShape)?.rotation ?? -99
    check("对照：按在对象上 Option 拖拽确实旋转", abs(rot2After - rot2Before) > 0.01,
          "rotation \(rot2Before) → \(rot2After)")

    // C) 短粗箭头：**看得见的头**必须能被 Option 抓住
    //
    // 头部长度随线宽放大（线宽 30 → 96pt），而 `boundingBox` 的 padding 一度仍用
    // 样式自带的 14 —— 于是可见头部有一圈落在包围盒之外，按在头上 Option 拖拽
    // 却转不动它（用户看到的是"这个头点不动"）。
    //
    // 抓取点 (232, 200) 是刻意挑的**有判别力**的位置：三角头的后缘在 x=227
    // （尖端 310 − 头长 96·cos30°），所以它落在可见头部内；而旧包围盒 inset −8 后
    // 左边界是 248，所以它在旧门控**之外**。
    let v3 = AnnotationView(image: blankCanvas(600, 400))
    let k3 = v3.hitTestBuffer.generateUniqueColorKey()
    let thick = Arrow(startPoint: CGPoint(x: 300, y: 200), endPoint: CGPoint(x: 310, y: 200),
                      color: .black, lineWidth: 30, hitTestColorKey: k3, style: .default)
    v3.objects[k3] = thick
    v3.zOrder = [k3]
    v3.hitTestBuffer.drawObject(thick)
    v3.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 305, y: 200)))
    v3.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 305, y: 200)))
    check("短粗箭头能被点中选中", v3.selectedKey == k3,
          "selected=\(String(describing: v3.selectedKey))")

    let grab = CGPoint(x: 232, y: 200)
    let rot3Before = thick.rotation
    v3.mouseDown(with: mouse(.leftMouseDown, grab, .option))
    v3.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: grab.x, y: grab.y + 50), .option))
    v3.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: grab.x, y: grab.y + 50), .option))
    check("按在可见头部上 Option 拖拽能旋转（旧包围盒下这一下点不动）",
          abs(thick.rotation - rot3Before) > 0.01,
          String(format: "rotation %.4f → %.4f", rot3Before, thick.rotation))
}

// MARK: - 4. 水印文本实时同步

print("\n=== 4. 水印文本边打字边同步（不必按回车）===")
do {
    let window = AnnotationWindow(image: blankCanvas(400, 300))
    func findCanvas(_ v: NSView) -> AnnotationView? {
        if let c = v as? AnnotationView { return c }
        for s in v.subviews { if let c = findCanvas(s) { return c } }
        return nil
    }
    func findWatermarkField(_ v: NSView) -> NSTextField? {
        if let f = v as? NSTextField, f.placeholderString == "水印文本" { return f }
        for s in v.subviews { if let f = findWatermarkField(s) { return f } }
        return nil
    }
    guard let root = window.contentView,
          let canvas = findCanvas(root),
          let field = findWatermarkField(root) else {
        check("能拿到画布与水印输入框", false); exit(1)
    }

    field.stringValue = "机密-请勿外传"
    // 只做"打字"这一步：不回车、不失焦。旧实现此时 watermarkConfig.text 还是旧值。
    window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                            object: field))
    check("打字后立刻同步到 watermarkConfig（无需回车）",
          canvas.watermarkConfig.text == "机密-请勿外传",
          canvas.watermarkConfig.text)
    check("输入框已接上 delegate", field.delegate != nil)

    // 关窗确认是否真的接线（windowShouldClose 需要 delegate 才会被调用）
    check("标题栏 X 的关闭确认已接线（delegate 已设置）",
          window.delegate === window,
          window.delegate == nil ? "delegate 为 nil —— windowShouldClose 永远不会被调用" : "已设置")

    // ⌘Q 也要走同一道确认。
    //
    // 只覆盖 X 与「放弃」按钮等于留了个数据丢失的口子：按 ⌘Q 直接退出，
    // 图上的标注静默丢失。这里能自动验的是**接线**（且没有标注窗口时必须直接放行）；
    // "有未保存标注时会拦下来"复用的是同一个 confirmDiscardIfNeeded()，
    // 它的行为由上面那几条守着。
    let appDelegate = AppDelegate()
    let hasTerminateHook = appDelegate.responds(
        to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:)))
    check("⌘Q 的退出确认已接线（applicationShouldTerminate 已实现）",
          hasTerminateHook, hasTerminateHook ? "已实现" : "没实现 —— ⌘Q 会静默丢标注")
    check("没有标注窗口时退出直接放行，不无谓拦一下",
          appDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
          "\(appDelegate.applicationShouldTerminate(NSApplication.shared))")

    // close() 必须触发 onClose —— AppDelegate 靠它把 annotationWindow 置回 nil。
    // 少了这一步，窗口关掉之后 ⌘Q 还会对着一个已经消失的窗口再问一次「放弃这张截图？」。
    var closeNotified = false
    window.onClose = { closeNotified = true }
    window.close()
    check("close() 会触发 onClose（AppDelegate 靠它清掉窗口引用）",
          closeNotified, closeNotified ? "已触发" : "没触发 —— ⌘Q 会问一个已关掉的窗口")
}

// MARK: - 5. 导出分辨率锚在源像素

print("\n=== 5. 导出分辨率锚在源图像素（不再随当前显示器）===")
do {
    func pixelSize(_ image: NSImage) -> (Int, Int)? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    // 故意取一个**不等于任何显示器倍率**的像素尺寸（1.5x）：
    // 旧实现走 NSImage.lockFocus()，在 2x 屏上会导出 400×200；锚在源像素才是 300×150。
    let view = AnnotationView(image: blankCanvas(200, 100),
                              pixelSize: CGSize(width: 300, height: 150))
    let got = pixelSize(view.compositeImage()) ?? (0, 0)
    check("导出像素尺寸 = 显式传入的源像素尺寸", got == (300, 150),
          "\(got.0)×\(got.1)（期望 300×150；若按屏幕倍率会是 400×200 或 200×100）")

    // 对照：不显式传时退回 representation 的像素尺寸，不应崩
    let fallback = AnnotationView(image: blankCanvas(200, 100))
    let got2 = pixelSize(fallback.compositeImage()) ?? (0, 0)
    check("不传像素尺寸时仍能导出（走 representation 兜底）",
          got2.0 >= 200 && got2.1 >= 100, "\(got2.0)×\(got2.1)")
}

// MARK: - 6. HitTestBuffer 状态隔离

print("\n=== 6. HitTestBuffer 状态隔离（前一个对象的线型不泄漏给下一个）===")
do {
    /// 一个"故意留下虚线状态"的假对象 —— 现成的矩形/圆都会自己重置线型，
    /// 所以只有这种对象才能把"状态泄漏"暴露出来。新加的图形类型如果忘了重置，
    /// 就是这个样子。
    final class SloppyObject: AnnotationObject {
        let id = UUID()
        let hitTestColorKey: UInt32
        var center = CGPoint(x: 60, y: 100)
        var rotation: CGFloat = 0
        var color: NSColor = .red
        init(key: UInt32) { hitTestColorKey = key }
        var boundingBox: CGRect { CGRect(x: 20, y: 80, width: 80, height: 40) }
        func draw(in ctx: CGContext) {}
        func drawHitTest(in ctx: CGContext, color: NSColor) {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(6)
            ctx.setLineDash(phase: 0, lengths: [6, 6])   // 故意不还原
            ctx.stroke(boundingBox)
        }
        func selectionHandlePoints() -> [CGPoint] { [] }
        func snapPoints() -> [SnapPoint] { [] }
        func nearestPerimeterPoint(to point: CGPoint) -> CGPoint { center }
        // 协议在 2026-09-28 补了这两个（附着闭环）。stub 也必须表态 —— 这正是
        // "不给默认实现"的用意：新类型不实现就编译不过，不会静默退化成"参数恒为 0"。
        func pointOnPerimeter(at parameter: CGFloat) -> CGPoint { center }
        func perimeterParameter(for point: CGPoint) -> CGFloat { 0 }
        func move(by delta: CGVector) {}
        func rotate(by angle: CGFloat) {}
        func scale(by factor: CGFloat) {}
    }

    /// 第二个对象：只画自己的形状，**完全不碰线型**。
    ///
    /// 用现成的矩形测不出隔离 —— 因为矩形的 `drawHitTest` 自己会 `setLineDash([])`
    /// 把状态重置掉，泄漏被对象挡住了（第一版探针就是这么写的，去掉 save/restore
    /// 后照样通过，等于没测）。真正能暴露隔离缺失的，是"假设缓冲区会给它干净状态"
    /// 的对象 —— 那正是新增图形类型最常见的样子。
    final class PlainObject: AnnotationObject {
        let id = UUID()
        let hitTestColorKey: UInt32
        let box: CGRect
        var rotation: CGFloat = 0
        var color: NSColor = .black

        init(key: UInt32, box: CGRect) { hitTestColorKey = key; self.box = box }
        var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
        var boundingBox: CGRect { box }
        func draw(in ctx: CGContext) {}
        func drawHitTest(in ctx: CGContext, color: NSColor) {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(8)
            ctx.stroke(box)          // 不设线型 —— 依赖缓冲区给干净状态
        }
        func selectionHandlePoints() -> [CGPoint] { [] }
        func snapPoints() -> [SnapPoint] { [] }
        func nearestPerimeterPoint(to point: CGPoint) -> CGPoint { center }
        // 协议在 2026-09-28 补了这两个（附着闭环）。stub 也必须表态 —— 这正是
        // "不给默认实现"的用意：新类型不实现就编译不过，不会静默退化成"参数恒为 0"。
        func pointOnPerimeter(at parameter: CGFloat) -> CGPoint { center }
        func perimeterParameter(for point: CGPoint) -> CGFloat { 0 }
        func move(by delta: CGVector) {}
        func rotate(by angle: CGFloat) {}
        func scale(by factor: CGFloat) {}
    }

    let view = AnnotationView(image: blankCanvas(400, 200))
    let sloppyKey = view.hitTestBuffer.generateUniqueColorKey()
    let plainKey = view.hitTestBuffer.generateUniqueColorKey()

    view.hitTestBuffer.clear()
    view.hitTestBuffer.drawObject(SloppyObject(key: sloppyKey))          // 留下虚线状态
    view.hitTestBuffer.drawObject(PlainObject(key: plainKey,
                                              box: CGRect(x: 250, y: 70, width: 100, height: 60)))

    // 沿它的下边扫：干净状态下应当连续命中，被虚线污染则出现空洞
    var hits = 0, samples = 0
    for x in 255...345 {
        samples += 1
        if view.hitTestBuffer.pickColorKey(at: CGPoint(x: CGFloat(x), y: 70)) == plainKey {
            hits += 1
        }
    }
    let ratio = Double(hits) / Double(max(samples, 1))
    check("前一个对象的虚线没有泄漏给下一个对象（命中区连续）",
          ratio > 0.95, String(format: "下边命中率 %.0f%%（%d/%d）", ratio * 100, hits, samples))
}

// MARK: - 7. 窗口挑选过滤

print("\n=== 7. 窗口挑选：过滤掉不可截图的窗口 ===")
do {
    let ownPID: Int32 = 999
    let point = CGPoint(x: 100, y: 100)

    func win(pid: Int32, layer: Int, alpha: Double,
             _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, id: UInt32) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
         kCGWindowNumber as String: id]
    }

    let list: [[String: Any]] = [
        win(pid: 100, layer: 0, alpha: 1, 50, 50, 100, 100, id: 1),      // 普通窗口 → 应入选
        win(pid: 101, layer: 25, alpha: 1, 0, 0, 2000, 30, id: 2),       // 菜单栏层 → 排除
        win(pid: 102, layer: 0, alpha: 0, 50, 50, 100, 100, id: 3),      // 全透明 → 排除
        win(pid: 103, layer: 0, alpha: 1, 50, 50, 0, 0, id: 4),          // 零尺寸 → 排除
        win(pid: ownPID, layer: 0, alpha: 1, 50, 50, 100, 100, id: 5),   // 自身进程 → 排除
        win(pid: 104, layer: 0, alpha: 1, 300, 300, 50, 50, id: 6),      // 不含该点 → 排除
    ]

    let got = ScreenCapture.windowCandidates(from: list, at: point, ownPID: ownPID)
    check("只留下可截图的普通窗口", got.count == 1 && got.first?.id == 1,
          "入选 \(got.count) 个：\(got.map { $0.id })")
}

// MARK: - 8. 选中对象改色 / 改线宽（可撤销）

print("\n=== 8. 选中对象可直接换色 / 改线宽，且可撤销 ===")
do {
    let view = AnnotationView(image: blankCanvas(400, 300))
    let key = view.hitTestBuffer.generateUniqueColorKey()
    let rect = RectangleShape(center: CGPoint(x: 200, y: 150), width: 120, height: 80,
                              color: .systemRed, lineWidth: 8, hitTestColorKey: key)
    view.objects[key] = rect
    view.zOrder = [key]
    view.selectedKey = key

    let undoBefore = view.undoStack.count
    let changed = view.restyleSelection(color: .systemBlue)
    check("换色真的作用到选中对象上",
          changed && rect.color.usingColorSpace(.deviceRGB)?.blueComponent ?? 0 > 0.8,
          "颜色已变")

    view.restyleSelection(lineWidth: 24)
    check("改线宽作用到选中对象上", AnnotationView.lineWidth(of: rect) == 24,
          "\(AnnotationView.lineWidth(of: rect) ?? -1)")
    check("两次改动各记了一步撤销", view.undoStack.count == undoBefore + 2,
          "\(undoBefore) → \(view.undoStack.count)")

    // 撤销回线宽，再撤销回颜色
    view.performUndo()
    check("撤销改线宽", AnnotationView.lineWidth(of: rect) == 8,
          "\(AnnotationView.lineWidth(of: rect) ?? -1)")
    view.performUndo()
    let backToRed = rect.color.usingColorSpace(.deviceRGB)?.redComponent ?? 0
    check("撤销换色", backToRed > 0.8, String(format: "红分量 %.2f", backToRed))

    // 重做方向。**这一段此前是缺的**：只验了撤销，于是 restyle 的 redo 记录
    // 在"已经把颜色改回旧值"之后才去读 `obj.color`，新旧值相等，重做成了空操作
    // —— 撤销两次再重做两次，颜色与线宽都回不到新值，而探针全绿。
    view.performRedo()
    let redoneBlue = rect.color.usingColorSpace(.deviceRGB)?.blueComponent ?? 0
    check("重做换色：颜色回到新值", redoneBlue > 0.8, String(format: "蓝分量 %.2f", redoneBlue))
    view.performRedo()
    check("重做改线宽：线宽回到新值", AnnotationView.lineWidth(of: rect) == 24,
          "\(AnnotationView.lineWidth(of: rect) ?? -1)")

    // 没有选中对象时应当安全地什么都不做
    view.selectedKey = nil
    check("无选中时 restyle 安全返回 false", view.restyleSelection(color: .green) == false)
}

// MARK: - 9. 权限判定：不破坏已授权的情况

print("\n=== 9. 权限判定 ===")
do {
    // 这一节默认**整节跳过**，原因不是它不重要，而是它有副作用：
    //
    // 任何一次真实的抓屏请求（`SCShareableContent` / `CGWindowListCreateImage`）都会让
    // **这个探针二进制**被登记进「系统设置 → 隐私与安全性 → 屏幕录制」列表。探针每次都
    // 在新的临时路径里编译，于是跑一次就多一条垃圾记录；而这类按路径识别的裸可执行文件
    // `tccutil reset` 清不掉（报 "No such bundle identifier"），只能手动删。
    // 2026-09-28 实测踩到：列表里冒出了 `run` 等条目。
    //
    //   AISNAP_PROBE_ALLOW_CAPTURE=1 ./probes/run_all.sh master_parity    # 要验时显式打开
    //
    // 默认状态下只读 preflight —— 那个 API 不发起抓屏请求、不登记。
    let allowCapture = ProcessInfo.processInfo.environment["AISNAP_PROBE_ALLOW_CAPTURE"] == "1"
    let preflight = CGPreflightScreenCaptureAccess()
    if allowCapture {
        let delegate = AppDelegate()
        // 权限预检已 async 化（不再用信号量卡主线程）。探针是顶层代码，可以直接 await。
        let sck = await delegate.canQueryShareableContent()
        let decided = await delegate.checkScreenCapturePermission()
        check("preflight 为真时判定必须为真", !preflight || decided,
              "preflight=\(preflight) 判定=\(decided)")
        check("已授权时实时探测也得说有权限（不然会误报缺权限）", !preflight || sck,
              "preflight=\(preflight) SCK 探测=\(sck)")
        print("     [INFO] 无权限方向（本进程构造不出来）见 probes/permission_probe.swift")
    } else {
        print("     [INFO] 已跳过（本机 preflight=\(preflight)）—— 实时探测会往"
              + "「屏幕录制」列表里加一条记录，默认不跑")
        print("     [INFO] 要跑：AISNAP_PROBE_ALLOW_CAPTURE=1 ./probes/run_all.sh master_parity")
    }
}

// MARK: - 10. 窗口挑选：浮层不能跳过、系统层必须挡掉

print("\n=== 10. 窗口挑选：浮层不跳过、程序坞/菜单栏挡掉 ===")
do {
    // 注意字典值的类型必须是 CGFloat：windowCandidates 里是 `as? [String: CGFloat]`，
    // 用 Int 字面量会整条转换失败、函数返回空数组 —— 合成用例时踩过这个坑。
    func win(_ id: UInt32, pid: Int32, layer: Int, alpha: Double,
             _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [String: Any] {
        [kCGWindowNumber as String: id,
         kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h]]
    }
    let point = CGPoint(x: 100, y: 100)
    // Z 序：最前面的在前
    let list = [
        win(1, pid: 900, layer: 3,  alpha: 1.0, 0, 0, 400, 400),      // 浮动面板（在前）
        win(2, pid: 901, layer: 0,  alpha: 1.0, 0, 0, 400, 400),      // 普通窗口（在后）
        win(3, pid: 902, layer: 20, alpha: 1.0, 0, 0, 2000, 2000),    // 程序坞（铺满全屏）
        win(4, pid: 903, layer: 24, alpha: 1.0, 0, 0, 2000, 30),      // 菜单栏
        win(5, pid: 904, layer: -1, alpha: 1.0, 0, 0, 400, 400),      // 通知中心
        win(6, pid: 999, layer: 0,  alpha: 1.0, 0, 0, 400, 400),      // 自己（应按 pid 排除）
    ]
    let got = ScreenCapture.windowCandidates(from: list, at: point, ownPID: 999).map { $0.id }
    // 浮层若被跳过，就会去截它**后面**那个窗口 —— 用户点的明明是浮窗却拿到别的东西
    check("浮层窗口在候选里，且按 Z 序排在普通窗口前面", got == [1, 2], "\(got)")
    check("程序坞 / 菜单栏 / 通知中心被挡掉", !got.contains(3) && !got.contains(4) && !got.contains(5),
          "\(got)")
    check("自己的窗口按 pid 排除", !got.contains(6), "\(got)")
}

// MARK: - 11. 线宽滑杆：一次拖拽只记一条撤销

print("\n=== 11. 线宽滑杆一次拖拽只记一条撤销 ===")
do {
    let window = AnnotationWindow(image: blankCanvas(400, 300))
    func findCanvas(_ v: NSView) -> AnnotationView? {
        if let c = v as? AnnotationView { return c }
        for s in v.subviews { if let c = findCanvas(s) { return c } }
        return nil
    }
    func findSlider(_ v: NSView) -> GestureReportingSlider? {
        if let s = v as? GestureReportingSlider { return s }
        for s in v.subviews { if let f = findSlider(s) { return f } }
        return nil
    }
    guard let root = window.contentView,
          let canvas = findCanvas(root),
          let slider = findSlider(root) else {
        check("能拿到画布与线宽滑杆", false); exit(1)
    }

    // 选中一个对象，滑杆才会作用到它身上
    let key = canvas.hitTestBuffer.generateUniqueColorKey()
    let rect = RectangleShape(center: CGPoint(x: 200, y: 150), width: 120, height: 80,
                              color: .black, lineWidth: 15, hitTestColorKey: key)
    canvas.objects[key] = rect
    canvas.zOrder = [key]
    canvas.selectedKey = key

    let before = canvas.undoStack.count
    slider.onGestureBegin?()                                   // ≈ 按下鼠标
    for v in stride(from: 15.0, through: 30.0, by: 0.25) {     // ≈ 连续拖拽（61 次 action）
        slider.doubleValue = v
        _ = slider.sendAction(slider.action, to: slider.target)
    }
    let mid = canvas.undoStack.count
    slider.onGestureEnd?()                                     // ≈ 松开鼠标
    let after = canvas.undoStack.count

    check("拖拽过程中实时改但不记撤销", mid == before, "\(before) → \(mid)")
    check("松手后只多一条撤销", after == before + 1, "\(before) → \(after)")
    check("线宽改到了终点值", AnnotationView.lineWidth(of: rect) == 30,
          "\(AnnotationView.lineWidth(of: rect) ?? -1)")

    // 一次 ⌘Z 就该退回拖拽**起点**，而不是退回 0.25px（旧实现要按几十次）
    canvas.performUndo()
    check("一次撤销就退回拖拽起点 15（而不是退一小步）",
          AnnotationView.lineWidth(of: rect) == 15,
          "\(AnnotationView.lineWidth(of: rect) ?? -1)")
}

// MARK: - 12. 区域截图路径：「放弃」按钮必须真的关窗

print("\n=== 12. borderless（区域截图）上「放弃」必须真的关窗 ===")
do {
    // 区域截图那条路是 `.borderless`（没有 `.closable`），而 AppKit 对这类窗口的
    // `performClose` 只响一声、**不关窗**。曾经「放弃」就是走 performClose 的，
    // 于是这条**主路径**上按钮完全没反应（窗口截图那条有标题栏 X 兜着，反而正常）。
    // 这里直接调按钮的动作，验它确实把窗关掉 —— 没有任何标注，所以不会弹确认框。
    let borderless = AnnotationWindow(image: blankCanvas(400, 300),
                                      anchor: NSRect(x: 100, y: 100, width: 200, height: 150))
    borderless.makeKeyAndOrderFront(nil)
    check("区域截图窗口确实是 borderless（没有 .closable）",
          !borderless.styleMask.contains(.closable), "\(borderless.styleMask.rawValue)")
    borderless.discardAndClose()
    check("「放弃」把区域截图窗口关掉了（走 performClose 时会留着不关）",
          !borderless.isVisible,
          borderless.isVisible ? "窗口还在 —— 按钮又是死的" : "已关闭")

    // 对照：窗口截图那条路（有 .closable）本来就能关，确认没被改坏
    let titled = AnnotationWindow(image: blankCanvas(400, 300), anchor: nil)
    titled.makeKeyAndOrderFront(nil)
    titled.discardAndClose()
    check("对照：窗口截图那条路的「放弃」也正常", !titled.isVisible, "已关闭")
}

// MARK: - 13. 调试面板隐藏时不渲染（显示时必须补上）

print("\n=== 13. 调试面板隐藏时不做事、显示时有内容 ===")
do {
    let window = AnnotationWindow(image: blankCanvas(400, 300))
    func findCanvas(_ v: NSView) -> AnnotationView? {
        if let c = v as? AnnotationView { return c }
        for s in v.subviews { if let c = findCanvas(s) { return c } }
        return nil
    }
    guard let root = window.contentView, let canvas = findCanvas(root),
          let panel = canvas.debugImageView else {
        check("能拿到画布与调试面板", false); exit(1)
    }
    let key = canvas.hitTestBuffer.generateUniqueColorKey()
    canvas.objects[key] = RectangleShape(center: CGPoint(x: 200, y: 150), width: 100, height: 60,
                                         color: .black, lineWidth: 8, hitTestColorKey: key)
    canvas.zOrder = [key]

    check("调试面板默认是隐藏的", panel.isHidden, "isHidden=\(panel.isHidden)")
    canvas.refreshDebugView()
    check("面板隐藏时 refreshDebugView 不做渲染（省掉每帧整幅拷贝）",
          panel.image == nil,
          panel.image == nil ? "没渲染" : "仍然渲染了 —— 白花一次全画布拷贝")

    // 显示时必须补一次，否则面板会是一片空白
    panel.isHidden = false
    canvas.refreshDebugView()
    check("面板显示时能渲染出内容（没被上一条优化连累成空白）",
          panel.image != nil, panel.image == nil ? "空白" : "有内容")
    window.close()
}

// MARK: - 14. 拖拽期间的命中层优化不能弄坏「选中」

print("\n=== 14. 挪动对象后仍能按新位置选中（命中层欠账会被补上）===")
do {
    let view = AnnotationView(image: blankCanvas(600, 400))
    let key = view.hitTestBuffer.generateUniqueColorKey()
    let rect = RectangleShape(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 200),
                              color: .black, lineWidth: 8, hitTestColorKey: key)
    view.objects[key] = rect
    view.zOrder = [key]
    view.hitTestBuffer.drawObject(rect)

    // 选中它
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 160, y: 100)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 160, y: 100)))
    check("先能选中", view.selectedKey == key, "\(String(describing: view.selectedKey))")

    // 拖到右边去：拖拽期间命中层只记脏、不重绘（见 flushHitLayerIfNeeded）
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 160, y: 100)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 360, y: 100)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 360, y: 100)))

    view.selectedKey = nil
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 360, y: 100)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 360, y: 100)))
    check("挪动之后，按**新位置**能选中它（命中层欠账被补上了）",
          view.selectedKey == key, "\(String(describing: view.selectedKey))")
}

// MARK: - 15. 取色器切走再切回来仍然可用（释放后必须能重新装载）

print("\n=== 15. 取色器采样器释放后能重新装载 ===")
do {
    // 画布上先放一块**确定颜色**的区域：只有这样断言才有判别力 ——
    // 纯白画布上"取到了白色"和"根本没取样、只是把 currentColor 留成初值"分不开。
    let canvas = blankCanvas(400, 300)
    canvas.lockFocus()
    NSColor(red: 0, green: 0, blue: 1, alpha: 1).setFill()
    NSRect(x: 100, y: 100, width: 200, height: 150).fill()
    canvas.unlockFocus()

    let view = AnnotationView(image: canvas)
    // 观测点用 currentColor（picker 分支在 mouseUp 时写回它），与 picker_probe 同一手法
    func pickAt(_ p: CGPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, p))
        view.mouseUp(with: mouse(.leftMouseUp, p))
    }
    func isBlue(_ c: NSColor) -> Bool {
        let d = c.usingColorSpace(.deviceRGB) ?? c
        return d.blueComponent > 0.8 && d.redComponent < 0.2
    }
    view.currentTool = .picker
    view.currentColor = .black
    pickAt(CGPoint(x: 200, y: 150))
    let first = view.currentColor

    // 切走（会释放整幅 RGBA 副本）再切回来 —— 释放必须不影响再次使用。
    // 写成 `lazy var` 的话这里会永久失效：lazy 只初始化一次，被赋过 nil 就不再装载。
    view.currentTool = .arrow
    view.currentTool = .picker
    view.currentColor = .black
    pickAt(CGPoint(x: 210, y: 160))
    let second = view.currentColor

    check("取色器取到的是画布上那块蓝色（不是初值、也没取错位置）",
          isBlue(first), "\(first)")
    check("切走再切回来仍能取到同一个蓝色（释放后可重新装载）",
          isBlue(second), "\(second) —— 若是黑色说明释放之后装不回来了")
}

// MARK: - 16. 被动吸附检测仍然正确

print("\n=== 16. 被动吸附检测（改写置脏条件时不能把它弄坏）===")
do {
    // 这一段原来写的是"吸附状态没变就不置脏"，但**离屏环境里 `needsDisplay` 不可观测**：
    // 视图不在窗口里时设 true 读回是 false，在窗口里时设 false 又读回 true ——
    // 那样的断言恒真、抓不到任何东西（实测：把修复退回旧写法它照样全绿）。
    //
    // 所以这里改锚在**可观测的吸附状态**上：那才是我重写这段代码时真正可能弄坏的东西
    // （置脏条件与状态赋值在同一段里）。至于"确实少重绘了"这个性能收益本身没有可靠的
    // 离屏可观测量，由代码审阅保证 —— 这一点在评审记录里写明。
    let view = AnnotationView(image: blankCanvas(600, 400))
    let key = view.hitTestBuffer.generateUniqueColorKey()
    let rect = RectangleShape(center: CGPoint(x: 100, y: 100), width: 60, height: 40,
                              color: .black, lineWidth: 4, hitTestColorKey: key)
    view.objects[key] = rect
    view.zOrder = [key]
    view.currentTool = .arrow

    guard let snap = rect.snapPoints().first else {
        check("矩形有吸附点", false); exit(1)
    }
    view.mouseMoved(with: mouse(.mouseMoved, snap.point))
    check("移到吸附点上时记下 activeSnapPoint（指示器才画得出来）",
          view.activeSnapPoint != nil, "\(String(describing: view.activeSnapPoint))")

    view.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 560, y: 380)))
    check("移开之后 activeSnapPoint 被清掉（指示器不该留在原地）",
          view.activeSnapPoint == nil, "\(String(describing: view.activeSnapPoint))")

    // 回到吸附点：状态要能再次被设上（证明"没变化才跳过"没有把状态机卡住）
    view.mouseMoved(with: mouse(.mouseMoved, snap.point))
    check("再移回吸附点，状态能重新设上",
          view.activeSnapPoint != nil, "\(String(describing: view.activeSnapPoint))")
}

// MARK: - 17. 形状缩不到「看不见」

print("\n=== 17. 各形状的本体尺寸有下限（判据不能用包围盒）===")
do {
    // `boundingBox` 含线宽 / 箭头头部这些**绘制外扩**：拿它当"最小 5pt"的判据时，
    // 形状本体可以一路缩到 0 而包围盒仍有几十点 —— 结果是对象变成一个看不见的点、
    // 却还留在图层里。这里对每种形状连缩 60 次（每次减半），断言本体没塌掉。
    func report(_ w: CGFloat, _ h: CGFloat) -> String { String(format: "%.4f × %.4f", w, h) }

    let rect = RectangleShape(center: CGPoint(x: 200, y: 150), width: 120, height: 100,
                              color: .black, lineWidth: 15, hitTestColorKey: 1)
    for _ in 0..<60 { rect.scale(by: 0.5) }
    check("矩形本体不会缩到看不见", rect.width >= 4 - 0.01 && rect.height >= 4 - 0.01,
          report(rect.width, rect.height))

    let circle = CircleShape(center: CGPoint(x: 200, y: 150), radiusX: 60, radiusY: 50,
                             color: .black, lineWidth: 15, hitTestColorKey: 2)
    for _ in 0..<60 { circle.scale(by: 0.5) }
    check("椭圆本体不会缩到看不见", circle.radiusX >= 2 - 0.01 && circle.radiusY >= 2 - 0.01,
          report(circle.radiusX, circle.radiusY))

    let spot = SpotlightShape(center: CGPoint(x: 200, y: 150), width: 120, height: 100,
                              hitTestColorKey: 3)
    for _ in 0..<60 { spot.scale(by: 0.5) }
    check("聚光灯本体不会缩到看不见", spot.width >= 4 - 0.01 && spot.height >= 4 - 0.01,
          report(spot.width, spot.height))

    let red = RedactionShape(center: CGPoint(x: 200, y: 150), width: 120, height: 100,
                             style: .mosaic(blockSize: 12), hitTestColorKey: 4)
    for _ in 0..<60 { red.scale(by: 0.5) }
    check("打码本体不会缩到看不见", red.width >= 4 - 0.01 && red.height >= 4 - 0.01,
          report(red.width, red.height))

    // 箭头：本体尺寸就是两端点距离
    let arrow = Arrow(startPoint: CGPoint(x: 100, y: 150), endPoint: CGPoint(x: 300, y: 150),
                      color: .black, lineWidth: 15, hitTestColorKey: 5, style: .default)
    func arrowLength(_ a: Arrow) -> CGFloat {
        hypot(a.endPoint.x - a.startPoint.x, a.endPoint.y - a.startPoint.y)
    }
    for _ in 0..<60 { arrow.scale(by: 0.5) }
    let shortLength = arrowLength(arrow)
    check("箭头长度不会缩到看不见", shortLength >= 4 - 0.01, String(format: "%.4f", shortLength))

    // 下限不能把**放大**也挡住 —— 那是本末倒置
    for _ in 0..<5 { arrow.scale(by: 2) }
    check("放大不受下限影响（下限只管缩小）", arrowLength(arrow) > shortLength * 20,
          String(format: "%.1f → %.1f", shortLength, arrowLength(arrow)))

    // 已经比下限还小的形状：再缩不该被"抬"大（max 的作用是止损，不是放大）
    let tiny = RectangleShape(center: CGPoint(x: 10, y: 10), width: 2, height: 2,
                              color: .black, lineWidth: 1, hitTestColorKey: 6)
    tiny.scale(by: 1.0)
    check("factor=1 不会改变尺寸", abs(tiny.width - 2) < 0.001, "\(tiny.width)")
}

// MARK: - 18. 贴图透明区穿透（低分辨率 alpha 掩码）

print("\n=== 18. 贴图透明区穿透判定（含上下方向）===")
do {
    // 下半透明、上半不透明。NSImage 的 lockFocus 坐标 y=0 在**底部**，
    // 视图 isFlipped == false 也是 y 向上 —— 两边一致才对。
    //
    // 掩码构建里如果把 y 搞反了，**不会有任何报错**，只会表现为"点哪儿都不对"，
    // 所以这里特别验方向。
    let img = NSImage(size: NSSize(width: 200, height: 100))
    img.lockFocus()
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 200, height: 100).fill()
    NSColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
    NSRect(x: 0, y: 50, width: 200, height: 50).fill()      // 上半不透明
    img.unlockFocus()

    let content = PinContentView(image: img)
    content.frame = NSRect(x: 0, y: 0, width: 200, height: 100)

    let topOpaque = content.isPassThrough(at: NSPoint(x: 100, y: 75))
    let bottomClear = content.isPassThrough(at: NSPoint(x: 100, y: 25))
    check("不透明区不吃穿透", topOpaque == false,
          topOpaque ? "把不透明区判成透明了" : "正常")
    check("全透明区要穿透（否则贴图会挡住下面的窗口）", bottomClear == true,
          bottomClear ? "正常" : "没穿透 —— 掩码没建出来或方向反了")
    // 两个方向必须给出不同答案，才说明 y 没有被整体翻过来
    check("上下判定不能同号（y 方向搞反时会同号）",
          topOpaque != bottomClear,
          "上=\(topOpaque) 下=\(bottomClear)")

    // 普通截图（完全不透明）不能被穿透 —— 这是"改动不影响原有手感"的底线
    let opaque = blankCanvas(200, 100)
    let plain = PinContentView(image: opaque)
    plain.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
    check("完全不透明的普通截图不会被穿透",
          plain.isPassThrough(at: NSPoint(x: 100, y: 50)) == false, "正常")
}

// MARK: - 19. 附着系统闭环：每种形状都能「挂上 → 跟得上」

print("\n=== 19. 附着闭环（挂上必须解析得回来，否则会出现\"不跟却被删\"）===")
do {
    // 曾经的问题：`computePerimeterParameter` 只认 Circle/Rectangle/Stamp/Text，
    // 别的类型返回 0；而 `resolveAttachmentPosition` 也只认那四种 ——
    // 于是 Redaction/Spotlight/StepBadge 能"挂上"，但父对象移动时箭头不跟，
    // 父对象删除时箭头却被级联删掉。
    //
    // 现在两个方向都走协议，且协议**没有默认实现** —— 新形状不表态就编译不过。
    func makeAllParents() -> [(String, any AnnotationObject)] {
        let rect = RectangleShape(center: CGPoint(x: 200, y: 150), width: 120, height: 90,
                                  color: .black, lineWidth: 4, hitTestColorKey: 1)
        let circle = CircleShape(center: CGPoint(x: 200, y: 150), radiusX: 60, radiusY: 40,
                                 color: .black, lineWidth: 4, hitTestColorKey: 2)
        let stamp = StampObject(center: CGPoint(x: 200, y: 150), size: 80,
                                stampType: .checkmark, hitTestColorKey: 3)
        let badge = StepBadge(center: CGPoint(x: 200, y: 150), number: 1, radius: 40,
                              color: .red, hitTestColorKey: 4)
        let text = TextShape(center: CGPoint(x: 200, y: 150), text: "hi",
                             fontSize: 24, hitTestColorKey: 5)
        let spot = SpotlightShape(center: CGPoint(x: 200, y: 150), width: 120, height: 90,
                                  hitTestColorKey: 6)
        let red = RedactionShape(center: CGPoint(x: 200, y: 150), width: 120, height: 90,
                                 style: .mosaic(blockSize: 12), hitTestColorKey: 7)
        return [("矩形", rect), ("椭圆", circle), ("印章", stamp), ("序号", badge),
                ("文字", text), ("聚光灯", spot), ("打码", red)]
    }

    // ① 参数与坐标必须**互逆**（附着就是靠这一对：记录时点→参数，解析时参数→点）
    var roundTripBad: [String] = []
    for (name, obj) in makeAllParents() {
        for i in 0...10 {
            let want = CGFloat(i) / 10
            let back = obj.perimeterParameter(for: obj.pointOnPerimeter(at: want))
            // 参数 1.0 与 0.0 是同一个点，允许归一化到 0
            let diff = min(abs(back - want), abs(back - want + 1), abs(back - want - 1))
            if diff > 0.01 { roundTripBad.append(String(format: "%@ %.1f→%.3f", name, want, back)) }
        }
    }
    check("每种形状的「参数 ↔ 坐标」都互逆（附着记录/解析靠这一对）",
          roundTripBad.isEmpty, roundTripBad.isEmpty ? "11 个参数点 × 7 种形状全部通过"
                                                    : roundTripBad.prefix(3).joined(separator: ", "))

    // ② 端到端：挂上去之后，父对象移动 → 箭头端点必须跟着走
    var notFollowing: [String] = []
    for (name, parent) in makeAllParents() {
        let view = AnnotationView(image: blankCanvas(600, 400))
        let pKey = view.hitTestBuffer.generateUniqueColorKey()
        view.objects[pKey] = parent
        let aKey = view.hitTestBuffer.generateUniqueColorKey()
        let arrow = Arrow(startPoint: CGPoint(x: 400, y: 300), endPoint: CGPoint(x: 500, y: 300),
                          color: .black, lineWidth: 4, hitTestColorKey: aKey, style: .default)
        arrow.endAttachment = Attachment(parentKey: pKey, anchorType: .perimeter(parameter: 0.25))
        view.objects[aKey] = arrow
        view.zOrder = [pKey, aKey]

        let before = view.resolveAttachmentPosition(arrow.endAttachment!) ?? .zero
        parent.move(by: CGVector(dx: 40, dy: 25))
        view.updateAttachedArrows(forParent: pKey)
        let after = view.resolveAttachmentPosition(arrow.endAttachment!) ?? .zero

        // 端点应落在（移动后的）父对象周长上，且确实变了
        let expected = parent.pointOnPerimeter(at: 0.25)
        let onPerimeter = hypot(after.x - expected.x, after.y - expected.y) < 0.5
        let moved = hypot(after.x - before.x, after.y - before.y) > 30
        let tipFollowed = hypot(arrow.endPoint.x - after.x, arrow.endPoint.y - after.y) < 0.5
        if !(onPerimeter && moved && tipFollowed) {
            notFollowing.append(String(format: "%@(周长上=%@ 跟随=%@ 端点贴合=%@)", name,
                                       onPerimeter ? "是" : "否", moved ? "是" : "否",
                                       tipFollowed ? "是" : "否"))
        }
    }
    check("父对象移动后，附着箭头跟着走（5 个类型曾经完全不动）",
          notFollowing.isEmpty, notFollowing.isEmpty ? "7 种形状全部跟随" : notFollowing.joined(separator: ", "))

    // ③ detectAttachment 对每种形状都要给出**解析得回来**的锚点
    var unresolvable: [String] = []
    for (name, parent) in makeAllParents() {
        let view = AnnotationView(image: blankCanvas(600, 400))
        let pKey = view.hitTestBuffer.generateUniqueColorKey()
        view.objects[pKey] = parent
        view.zOrder = [pKey]
        // 取周长上的一点作为"落点"
        let onEdge = parent.pointOnPerimeter(at: 0.3)
        if let att = view.detectAttachment(at: onEdge, excludeKey: nil),
           att.parentKey == pKey {
            if view.resolveAttachmentPosition(att) == nil { unresolvable.append(name) }
        }
    }
    check("detectAttachment 给出的附着必须能解析回坐标（否则就是「不跟却被删」）",
          unresolvable.isEmpty, unresolvable.isEmpty ? "全部可解析" : "解析不了：\(unresolvable.joined(separator: ", "))")
}

// MARK: - 20. 文字形状的周长也推边（上轮收敛漏了它）

print("\n=== 20. 文字在框内的点也要推到边上 ===")
do {
    let text = TextShape(center: CGPoint(x: 200, y: 150), text: "hello",
                         fontSize: 20, hitTestColorKey: 1)
    let box = text.contentSize
    let hw = box.width / 2, hh = box.height / 2

    // 正中心：修复前会原样返回中心点（不在周长上）
    let c = text.nearestPerimeterPoint(to: CGPoint(x: 200, y: 150))
    let onEdge = abs(abs(c.x - 200) - hw) < 0.01 || abs(abs(c.y - 150) - hh) < 0.01
    check("框内点被推到周长上（原来原样返回框内点）", onEdge,
          String(format: "(%.1f,%.1f) 半宽半高 (%.1f,%.1f)", c.x, c.y, hw, hh))

    // 框外的点行为不变（回归保护）
    let out = text.nearestPerimeterPoint(to: CGPoint(x: 400, y: 150))
    check("框外的点仍按钳制处理（没有被改坏）", out.x > 200, String(format: "(%.1f,%.1f)", out.x, out.y))
}

// MARK: - 21. PNG 编码：不走 TIFF 中转，且像素逐位不变

print("\n=== 21. PNG 编码的像素必须与原图逐位一致 ===")
do {
    // 换编码器最容易悄悄改变颜色/透明度（尤其预乘 alpha 与色彩空间），
    // 而那种错用户只会觉得"存出来的图有点不对"。这里逐像素比对。
    let w = 4, h = 3
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    // 填一组带透明度、且各通道都不同的颜色
    let colors: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (1, 0, 0, 1), (0, 1, 0, 1), (0, 0, 1, 1), (1, 1, 0, 1),
        (0, 1, 1, 1), (1, 0, 1, 1), (0.25, 0.5, 0.75, 1), (0, 0, 0, 1),
        (1, 1, 1, 1), (0.5, 0.5, 0.5, 1), (0.1, 0.2, 0.3, 1), (0.9, 0.8, 0.7, 1),
    ]
    for y in 0..<h {
        for x in 0..<w {
            let c = colors[y * w + x]
            rep.setColor(NSColor(red: c.0, green: c.1, blue: c.2, alpha: c.3), atX: x, y: y)
        }
    }
    let image = NSImage(size: NSSize(width: w, height: h))
    image.addRepresentation(rep)

    let window = AnnotationWindow(image: image)
    guard let data = window.pngData(from: image),
          let decoded = NSBitmapImageRep(data: data) else {
        check("能编码出 PNG", false); exit(1)
    }
    check("PNG 像素尺寸与原图一致", decoded.pixelsWide == w && decoded.pixelsHigh == h,
          "\(decoded.pixelsWide)×\(decoded.pixelsHigh)")

    var diff = 0
    for y in 0..<h {
        for x in 0..<w {
            guard let a = rep.colorAt(x: x, y: y), let b = decoded.colorAt(x: x, y: y) else { continue }
            if abs(a.redComponent - b.redComponent) > 0.01
                || abs(a.greenComponent - b.greenComponent) > 0.01
                || abs(a.blueComponent - b.blueComponent) > 0.01
                || abs(a.alphaComponent - b.alphaComponent) > 0.01 { diff += 1 }
        }
    }
    check("PNG 每个像素都与原图一致（换编码器最容易在这里出错）",
          diff == 0, diff == 0 ? "\(w * h) 个像素全同" : "有 \(diff) 个像素不同")
    window.close()
}

// MARK: - 22. 导出像素尺寸的最后兜底不再假定 2×

print("\n=== 22. 拿不到位图 rep 时也不能凭空假定 2× ===")
do {
    // 一个**没有任何 representation** 的 NSImage：走不到"显式传入"与"rep 取像素"两条路，
    // 只能落到最后的兜底。原来那里写死 ×2（1x 屏上会凭空放大一倍、3x 屏上又少一截）。
    let bare = NSImage(size: NSSize(width: 120, height: 60))
    let view = AnnotationView(image: bare)          // 不传 pixelSize
    let out = view.compositeImage()
    let rep = out.representations.compactMap { $0 as? NSBitmapImageRep }.first
    let px = rep.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? "无"
    check("兜底取像素尺寸而不是点尺寸×2", px == "120×60",
          "得到 \(px)（写死 ×2 时会是 240×120）")
}

// MARK: - 23. 附着的端点要在画布上看得见

print("\n=== 23. 选中附着箭头时要画出锚点小环 ===")
do {
    // "挂上了"曾经在界面上毫无迹象：用户只能等移动父对象时发现箭头跟着动了才知道，
    // 而删掉父对象时箭头被一起删掉，那时更莫名其妙。
    func renderSelected(attached: Bool) -> (rep: NSBitmapImageRep, anchor: CGPoint, view: AnnotationView) {
        let view = AnnotationView(image: blankCanvas(400, 300))
        let pKey = view.hitTestBuffer.generateUniqueColorKey()
        let parent = RectangleShape(center: CGPoint(x: 120, y: 150), width: 100, height: 80,
                                    color: .black, lineWidth: 4, hitTestColorKey: pKey)
        view.objects[pKey] = parent
        let aKey = view.hitTestBuffer.generateUniqueColorKey()
        let arrow = Arrow(startPoint: CGPoint(x: 300, y: 60), endPoint: CGPoint(x: 300, y: 240),
                          color: .black, lineWidth: 4, hitTestColorKey: aKey, style: .default)
        if attached {
            arrow.startAttachment = Attachment(parentKey: pKey, anchorType: .perimeter(parameter: 0.5))
        }
        view.objects[aKey] = arrow
        view.zOrder = [pKey, aKey]
        view.selectedKey = aKey

        let anchor = view.resolveAttachmentPosition(arrow.startAttachment ?? Attachment(
            parentKey: pKey, anchorType: .perimeter(parameter: 0.5))) ?? .zero
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        return (rep, anchor, view)
    }

    /// 锚点周围一小圈里有没有"蓝色小环"的痕迹（蓝分量明显高于红/绿）
    ///
    /// 注意 y 要翻转：`colorAt` 的行号从**位图顶部**算，而视图坐标从**底部**算。
    /// （第一次写漏了这个翻转，结果"有环"那条假红 —— 而对照那条因为到处都没有环而
    /// 照样绿，正好说明**没有对照的失败是不可信的**。）
    func hasRing(_ rep: NSBitmapImageRep, at c: CGPoint, viewHeight: CGFloat) -> Bool {
        let cy = viewHeight - c.y
        for dx in -6...6 {
            for dy in -6...6 {
                let x = Int(c.x) + dx, y = Int(cy) + dy
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                      let col = rep.colorAt(x: x, y: y) else { continue }
                if col.blueComponent > 0.7 && col.redComponent < 0.6 && col.greenComponent < 0.8 {
                    return true
                }
            }
        }
        return false
    }

    let on = renderSelected(attached: true)
    check("选中附着箭头时，锚点处画出了小环", hasRing(on.rep, at: on.anchor, viewHeight: 300),
          String(format: "锚点 (%.0f,%.0f)", on.anchor.x, on.anchor.y))

    let off = renderSelected(attached: false)
    check("对照：没有附着时不画（否则等于到处画环）", !hasRing(off.rep, at: off.anchor, viewHeight: 300),
          "未附着时锚点处应无环")
}

// MARK: - 24. 拖拽箭头时预览附着锚点（落笔前就该看见）

print("\n=== 24. 拖拽箭头时，会附着的端点要当场标出来 ===")
do {
    // 附着是"看不见的状态"：落笔那一刻悄悄记下关系，之后要么父对象移动时箭头跟着走、
    // 要么父对象被删时箭头一起消失。原来**全程没有任何反馈**。
    //
    // 关键：这里故意把端点放在**边的中点**，它离该矩形的所有吸附点（4 角 + 中心）
    // 都 > 12pt —— 所以吸附指示器**不会**亮。这正好证明：
    //   · 看见锚点标记不是因为"吸附阈值被调大了"；
    //   · 吸附点指示与周长附着是两套东西（上一轮评审曾把这两件事混起来）。
    func renderDrag(to end: CGPoint) -> (rep: NSBitmapImageRep, view: AnnotationView) {
        let view = AnnotationView(image: blankCanvas(400, 300))
        let key = view.hitTestBuffer.generateUniqueColorKey()
        view.objects[key] = RectangleShape(center: CGPoint(x: 150, y: 150), width: 100, height: 80,
                                           color: .black, lineWidth: 4, hitTestColorKey: key)
        view.zOrder = [key]
        view.currentTool = .arrow
        view.currentColor = .black          // 别让红色的箭头干扰"找蓝色小环"
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 350, y: 40)))
        view.mouseDragged(with: mouse(.leftMouseDragged, end))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        return (rep, view)
    }

    func isRingBlue(_ c: NSColor) -> Bool {
        c.blueComponent > 0.7 && c.redComponent < 0.6 && c.greenComponent < 0.8
    }

    /// 全画布扫一遍有没有小环的蓝色（y 要翻转：位图行号从顶部算、视图从底部算）
    func anyRingInk(_ rep: NSBitmapImageRep) -> Bool {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                if let c = rep.colorAt(x: x, y: y), isRingBlue(c) { return true }
            }
        }
        return false
    }

    // 端点落在矩形上边、但**避开边中点**（x=125 而不是 150）：
    // 矩形的吸附点 = 中心 + 4 角 + **4 个边中点**，所以边中点本身就是吸附点 ——
    // 选在那里就成了"吸附指示亮着"，证明不了什么（第一版就是这么写错的）。
    // (125,190) 离最近的吸附点（(100,190) 与 (150,190)）各 25pt > 12，
    // 吸附指示**不会**亮，但它确实在周长上 —— 正是要验的情形。
    let onEdge = CGPoint(x: 125, y: 190)
    let hit = renderDrag(to: onEdge)
    check("端点贴着形状周长拖拽时，吸附指示器**没有**亮（与吸附点无关）",
          hit.view.activeSnapPoint == nil,
          "\(String(describing: hit.view.activeSnapPoint))")
    check("此时画面上出现了附着锚点小环（松手就会挂在这里）",
          anyRingInk(hit.rep), anyRingInk(hit.rep) ? "已画出" : "没画出来 —— 用户无从知道会附着")

    // 对照：拖到远离一切形状的地方 → 不该有任何小环
    let miss = renderDrag(to: CGPoint(x: 350, y: 260))
    check("对照：端点远离形状时不画锚点", !anyRingInk(miss.rep), anyRingInk(miss.rep) ? "不该有小环" : "无小环")
}

// MARK: - 25. 探针进程不该因为建了标注窗就变成 Dock 应用

print("\n=== 25. 构造标注窗不会让进程变成 Dock 应用 ===")
do {
    // `setupMainMenu` 会把激活策略切成 `.regular`（真应用要靠它露出菜单栏、进 Dock/⌘Tab）。
    // 探针是裸可执行文件，默认策略是 `.prohibited`；以前无条件切换，于是**每跑一个
    // 构造窗口的探针，Dock 里就蹦出一个叫 `run` 的图标**，跑一遍套件就是一路闪过去，
    // 还会把前台焦点抢走（用户实测报过）。
    //
    // 现在只在 `NSApp.delegate is AppDelegate` 时才切 —— 真应用的入口 main.swift 会设
    // delegate，探针不会。
    let before = NSApp.activationPolicy()
    let window = AnnotationWindow(image: blankCanvas(200, 150))
    window.makeKeyAndOrderFront(nil)
    let after = NSApp.activationPolicy()
    check("建窗（并上屏）之后进程仍不进 Dock",
          after != .regular,
          "before=\(before.rawValue) after=\(after.rawValue)")
    window.close()
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)