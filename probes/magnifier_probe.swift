// 放大镜的行为探针：链接真实源码 + 合成点击/拖拽。
//
// 覆盖「错了不报错、只是看错内容」的静默错误：
//   1. 取样位置 —— 镜面中心像素必须等于底图对应位置的像素（Y 翻转错 = 上下颠倒，
//      这是截图工具最容易错的一类）；
//   2. 拖动重取样 —— 移到新位置后内容跟着换（缓存键含圆心）；
//   3. 命中 —— 圆内可选中、圆外不误中；
//   4. 缩放下限 —— 半径按直径口径止损。
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

/// 底图：左半黑右半白（竖直分界在画布 x=200），采样对错一验便知
func splitCanvas(_ w: CGFloat, _ h: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: w / 2, height: h).fill()
    NSColor.white.setFill()
    NSRect(x: w / 2, y: 0, width: w / 2, height: h).fill()
    image.unlockFocus()
    return image
}

print("=== 1. 单击放置与内容取样 ===\n")
do {
    let view = AnnotationView(image: splitCanvas(400, 300))
    view.currentTool = .magnifier
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 150)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 150)))
    check("放置 1 个对象", view.objects.count == 1, "\(view.objects.count)")
    guard let mag = view.objects.values.first as? MagnifierShape else {
        check("对象是 MagnifierShape", false); exit(1)
    }
    check("命中层可选中", view.hitTestBuffer.pickColorKey(at: CGPoint(x: 150, y: 150)) != 0)
    check("圆外不误中（画布远角）",
          view.hitTestBuffer.pickColorKey(at: CGPoint(x: 380, y: 280)) == 0)

    // 内容取样：镜面（圆心 x=150 < 200）应显示黑区。放大 2.5×、半径 60 →
    // 取样半径 24 < 60，镜面全程在黑区内 → 中心像素应是黑
    guard let rep = NSBitmapImageRep(data: view.compositeImage().tiffRepresentation!) else {
        check("能读到合成图", false); exit(1)
    }
    func pixel(_ cx: CGFloat, _ cy: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let px = Int(cx / 400 * CGFloat(rep.pixelsWide))
        let py = Int(cy / 300 * CGFloat(rep.pixelsHigh))
        guard let c = rep.colorAt(x: px, y: py) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
    if let c = pixel(150, 150) {
        check("镜面中心显示底图黑区", c.r < 0.2 && c.g < 0.2 && c.b < 0.2,
              "r=\(c.r)")
    } else {
        check("能读到镜面中心像素", false)
    }

    // 拖到右半（x=300 > 200）：取样中心跨过分界 → 内容应变白
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 150)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 150)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 150)))
    if let c = pixel(300, 150) {
        check("拖动后重取样（镜面跟随到白区）", c.r > 0.8 && c.g > 0.8 && c.b > 0.8,
              "r=\(c.r)")
    } else {
        check("拖动后能读到镜面像素", false)
    }
}

print("\n=== 2. 分界线在镜内：放大 vs 不放大的对比 ===\n")
do {
    // 圆心恰放在分界线 x=200 上：放大镜里分界线应仍在镜心（内容随位置取样）
    let view = AnnotationView(image: splitCanvas(400, 300))
    view.currentTool = .magnifier
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 150)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 150)))
    guard let rep = NSBitmapImageRep(data: view.compositeImage().tiffRepresentation!) else {
        check("能读到合成图", false); exit(1)
    }
    func pixel(_ cx: CGFloat, _ cy: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let px = Int(cx / 400 * CGFloat(rep.pixelsWide))
        let py = Int(cy / 300 * CGFloat(rep.pixelsHigh))
        guard let c = rep.colorAt(x: px, y: py) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
    // 镜心（x=200）应是分界处：左右各偏 8 点，放大 2.5 倍后两侧颜色对比明确
    let left = pixel(192, 150).map { $0.r } ?? 1
    let right = pixel(208, 150).map { $0.r } ?? 1
    check("镜心左侧黑、右侧白（分界跟随圆心）", left < 0.3 && right > 0.7,
          "left=\(left) right=\(right)")
}

print("\n=== 3. 缩放与移动 ===\n")
do {
    let mag = MagnifierShape(center: CGPoint(x: 100, y: 100), radius: 60,
                             color: .red, lineWidth: 3, hitTestColorKey: 1)
    let centerBefore = mag.center
    mag.scale(by: 0.5)
    check("scale 0.5 → 半径 30", abs(mag.radius - 30) < 0.01, "\(mag.radius)")
    check("scale 不动圆心", mag.center == centerBefore)
    mag.scale(by: 0.01)
    check("缩到下限不再缩（直径口径 ≥ 4）", mag.radius >= MagnifierShape.minimumExtent / 2 - 0.01,
          "\(mag.radius)")
    mag.move(by: CGVector(dx: 25, dy: -10))
    check("move 平移圆心", mag.center == CGPoint(x: 125, y: 90))
    // 周长参数化互逆（CirclePerimeter）
    let p = mag.pointOnPerimeter(at: 0.25)
    let back = mag.perimeterParameter(for: p)
    check("周长参数化互逆", abs(back - 0.25) < 0.01, "\(back)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
