// 自由画笔/马克笔的行为探针：链接真实源码 + 合成鼠标事件。
//
// 覆盖四类「错了不报错、只是不对」的静默错误：
//   1. 平滑曲线不过采样点（视觉抖动/断触）—— 中点二次曲线必须过每个相邻中点、首尾精确；
//   2. 手绘对象没有进双图层（画得出选不中）—— 合成拖拽后按笔画上的点取色必须命中；
//   3. 缩放/移动破坏几何（质心漂移、笔画缩没）—— 以质心为锚的不变量逐项断言；
//   4. 马克笔叠深（来回涂抹颜色变深）—— 单次 stroke 不应自交叠深，像素实测。
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}
func mouse(_ type: NSEvent.EventType, _ p: CGPoint,
           flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0,
                       clickCount: 1, pressure: 1)!
}
func blankCanvas(_ w: CGFloat, _ h: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    image.unlockFocus()
    return image
}

print("=== 1. 平滑曲线的几何不变量 ===\n")
do {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 80), CGPoint(x: 100, y: 10),
                  CGPoint(x: 150, y: 90), CGPoint(x: 200, y: 40)]
    let shape = FreehandShape(points: points, color: .red, lineWidth: 3,
                              isMarker: false, hitTestColorKey: 7)
    check("center = 质心",
          abs(shape.center.x - 100) < 0.01 && abs(shape.center.y - 44) < 0.01,
          "\(shape.center)")
    // 包围盒盖住全部点 + 线宽 padding
    let box = shape.boundingBox
    check("包围盒盖住全部采样点",
          points.allSatisfy({ box.insetBy(dx: -3.5, dy: -3.5).contains($0) }), "\(box)")
    // 移动：所有点平移
    shape.move(by: CGVector(dx: 10, dy: -5))
    check("move 平移全部点（质心同步）",
          abs(shape.center.x - 110) < 0.01 && abs(shape.center.y - 39) < 0.01)
    // 缩放：主延伸变到下限之上、质心不动
    let centerBefore = shape.center
    shape.scale(by: 0.5)
    let boxAfter = shape.boundingBox
    let rawAfter = max(boxAfter.width, boxAfter.height)
    check("scale 0.5 后主延伸减半且不低于下限",
          rawAfter >= FreehandShape.minimumExtent * 0.99
          && rawAfter < box.width, "\(rawAfter)")
    check("scale 以质心为锚（质心不动）", shape.center == centerBefore,
          "\(shape.center) vs \(centerBefore)")

    // 周长参数化互逆：pointOnPerimeter(at: p) 的参数应回到 p
    let shape2 = FreehandShape(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                                        CGPoint(x: 100, y: 100)],
                               color: .red, lineWidth: 3,
                               isMarker: false, hitTestColorKey: 7)
    let mid = shape2.pointOnPerimeter(at: 0.5)
    let back = shape2.perimeterParameter(for: mid)
    check("周长参数化互逆（0.5 → 点 → 参数 ≈ 0.5）", abs(back - 0.5) < 0.01, "\(back)")
    let nearest = shape2.nearestPerimeterPoint(to: CGPoint(x: 120, y: 50))
    check("nearestPerimeterPoint 吸到最近边", nearest == CGPoint(x: 100, y: 50),
          "\(nearest)")
}

print("\n=== 2. 合成拖拽：进画布、可命中、可撤销 ===\n")
do {
    let view = AnnotationView(image: blankCanvas(400, 300))
    view.currentTool = .pen
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
    for (i, x) in stride(from: 60, through: 300, by: 20).enumerated() {
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: CGFloat(x),
                                                                 y: CGFloat(50 + (i % 2) * 10))))
    }
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 60)))
    check("一笔一个对象", view.objects.count == 1, "\(view.objects.count)")
    check("撤销栈有一条 add", view.undoStack.count == 1)

    // 命中：笔画经过的点必须能在 Layer B 里取到该对象
    guard let (key, obj) = view.objects.first else {
        check("能取到对象", false); exit(1)
    }
    let picked = view.hitTestBuffer.pickColorKey(at: CGPoint(x: 150, y: 55))
    check("笔画上的点能选中该对象", picked == key, "picked=\(picked) key=\(key)")
    check("对象类型是 FreehandShape（非马克）", (obj as? FreehandShape)?.isMarker == false)

    view.performUndo()
    check("undo 撤掉整条笔画", view.objects.isEmpty)
}

print("\n=== 3. 马克笔：半透明宽笔触 ===\n")
do {
    let view = AnnotationView(image: blankCanvas(400, 300))
    view.currentTool = .marker
    view.currentColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)   // 显式设色，不赌默认值
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 150)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 150)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 150)))
    guard let obj = view.objects.values.first as? FreehandShape else {
        check("马克笔对象生成", false); exit(1)
    }
    check("isMarker = true", obj.isMarker)

    // 像素实测：白底上画红马克，笔触中心应是「白×0.55 + 红×0.45」的浅红 ——
    // 通道值同时高于纯红、低于纯白
    guard let rep = NSBitmapImageRep(data: view.compositeImage().tiffRepresentation!) else {
        check("能读到合成图", false); exit(1)
    }
    // 画布 400×300 点，合成图像素 = 导出分辨率；笔画在画布 y=150（竖直中线）
    let scaleX = rep.pixelsWide / 400
    let midY = (150.0 / 300.0) * Double(rep.pixelsHigh)
    var blended = false
    for x in stride(from: 120, to: 260, by: 4) {
        if let c = rep.colorAt(x: x * scaleX, y: Int(midY)) {
            // 红@0.45 混白：红通道仍是 1（0.45×1 + 0.55×1），绿/蓝 = 0.55×1 = 0.549 ——
            // 「红通道饱和、绿蓝明显抬离 0」就是半透明红混白；纯不透明红则 g/b = 0
            if c.redComponent > 0.99
                && c.greenComponent > 0.2 && c.greenComponent < 0.9
                && c.blueComponent > 0.2 && c.blueComponent < 0.9 {
                blended = true
            }
        }
    }
    check("笔触是半透明混合（红饱和且绿蓝混白抬升）", blended)

    // 自交不叠深：来回涂抹同一段（同一笔画），中心颜色与单程一致
    view2: do {
        let v2 = AnnotationView(image: blankCanvas(400, 300))
        v2.currentTool = .marker
        v2.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 150)))
        v2.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 150)))
        v2.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 60, y: 150)))
        v2.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 60, y: 150)))
        guard let rep2 = NSBitmapImageRep(data: v2.compositeImage().tiffRepresentation!) else {
            check("能读到往返涂抹合成图", false); break view2
        }
        func redAt(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
            rep.colorAt(x: x, y: y)?.redComponent ?? 1
        }
        // 中心取一个肯定被涂过且不在折返端点附近的采样点
        let c1 = redAt(rep, Int(200.0 / 400.0 * Double(rep.pixelsWide)), Int(midY))
        let c2 = redAt(rep2, Int(200.0 / 400.0 * Double(rep2.pixelsWide)), Int(midY))
        check("往返涂抹不叠深（同点颜色一致）", abs(c1 - c2) < 0.05,
              "\(c1) vs \(c2)")
    }
}

print("\n=== 4. 抽稀与单点落笔 ===\n")
do {
    // 单击没拖：留一个圆点对象
    let view = AnnotationView(image: blankCanvas(400, 300))
    view.currentTool = .pen
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 100)))
    check("单击也留痕（1 个点对象）", view.objects.count == 1)
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
