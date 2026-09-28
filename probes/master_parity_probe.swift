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
    window.close()
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
