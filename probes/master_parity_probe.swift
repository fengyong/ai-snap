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
        let sck = delegate.canQueryShareableContent()
        let decided = delegate.checkScreenCapturePermission()
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

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)