// 矩形族边/角手柄调整大小的**多事件**拖拽探针。
//
// 为什么单独一个探针：已有的 resize_handle_probe 每次只发**一个** mouseDragged，
// 而手柄拖拽的真实路径是「按下 → 拖 N 次 → 松手」。两者不是同一条路径：
//   · mouseDown 把 startCenter / startWidth / startHeight 记进 .resizing 状态；
//   · 每次 mouseDragged 都用「光标相对 **startCenter**」算新的局部盒，
//     再把中心写成 worldCenter。
// 如果那次「写中心」是**相对增量**（obj.move(by:) 是相对的），
// 就会把「相对起始中心的位移」重复累加 —— 拖得越久偏得越远（二次增长），
// 而宽度始终是对的（宽度只依赖光标与 startCenter 的关系）。
//
// 契约：拖**右边**手柄时，**左边必须锚定不动**。
// 若中心漂移，左边就会跟着跑 —— 契约当场失效。
//
// ⚠️ **本探针当前是失败的**（断言的是「应该怎样」，代码还没改）。
//    它**故意没有**注册进 probes/run_all.sh。修好之后再加回去：
//
//      run_probe resize_drag_probe    "${ALL_SOURCES[@]}"
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
func key(_ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                     windowNumber: 0, context: nil, characters: "",
                     charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
}
func blankCanvas(_ w: CGFloat, _ h: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    image.unlockFocus()
    return image
}

/// 聚光灯 200×200，中心 (300,200)，左边 x=200，右边 x=400
func makeSelectedSpotlight() -> (AnnotationView, SpotlightShape) {
    let view = AnnotationView(image: blankCanvas(600, 400))
    view.currentTool = .spotlight
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 100)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 400, y: 300)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 300)))
    let spot = view.objects.values.first as! SpotlightShape
    view.keyDown(with: key(53))
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 200)))
    return (view, spot)
}

print("=== 1. 单次拖拽（已有探针覆盖的路径）：右边手柄 +30 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 430, y: 200)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 430, y: 200)))
    check("宽 200 → 230", abs(spot.width - 230) < 0.01, "\(spot.width)")
    check("左边锚定（中心 315）", abs(spot.center.x - 315) < 0.01, "center.x=\(spot.center.x)")
}

print("\n=== 2. 连续 10 次拖拽事件（真实拖拽路径）：中心不得累加漂移 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    for i in 1...10 {
        let x = 400 + CGFloat(i) * 10        // 410, 420, ... 500
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: x, y: 200)))
    }
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 500, y: 200)))

    // 契约：右边 x=500，左边必须仍然锚定在 x=200 → 宽 300，中心 350
    check("宽 200 → 300", abs(spot.width - 300) < 0.01, "\(spot.width)")
    check("左边仍锚定在 x=200（中心应为 350）", abs(spot.center.x - 350) < 0.01,
          "center.x=\(spot.center.x)")
    check("中心未跑出画布", spot.center.x < 600, "center.x=\(spot.center.x)")
}

print("\n=== 3. 连续 30 次拖拽事件：漂移量随事件数增长（二次型）===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    for i in 1...30 {
        let x = 400 + CGFloat(i) * 10
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: x, y: 200)))
    }
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 700, y: 200)))
    // 正确：宽 500、中心 450、左边仍在 200
    check("宽 200 → 500", abs(spot.width - 500) < 0.01, "\(spot.width)")
    check("左边仍锚定在 x=200（中心应为 450）", abs(spot.center.x - 450) < 0.01,
          "center.x=\(spot.center.x)")
}

print("\n=== 4. 拖角手柄：同样不得累加漂移 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 100)))   // cornerBR
    for i in 1...10 {
        let x = 400 + CGFloat(i) * 5
        let y = 100 - CGFloat(i) * 4
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: x, y: y)))
    }
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 450, y: 60)))
    // 对角锚定在左上 (200,300)：宽 250、高 240 → 中心 (325,180)
    check("宽 200 → 250", abs(spot.width - 250) < 0.01, "\(spot.width)")
    check("高 200 → 240", abs(spot.height - 240) < 0.01, "\(spot.height)")
    check("对角锚定（中心应为 325,180）",
          abs(spot.center.x - 325) < 0.01 && abs(spot.center.y - 180) < 0.01,
          "center=\(spot.center)")
}

print("\n=== 5. 矩形族同样受影响（同一协议路径）===\n")
do {
    let view = AnnotationView(image: blankCanvas(600, 400))
    view.currentTool = .rectangle
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 250)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 250)))
    view.keyDown(with: key(53))
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 175)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 175)))
    guard let rect = view.objects.values.first as? RectangleShape else {
        check("能取到矩形", false); exit(1)
    }
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 175)))
    for i in 1...10 {
        let x = 300 + CGFloat(i) * 4
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: x, y: 175)))
    }
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 340, y: 175)))
    // 左边 x=100 锚定，右边 340 → 宽 240，中心 220
    check("宽 200 → 240", abs(rect.width - 240) < 0.01, "\(rect.width)")
    check("左边仍锚定（中心应为 220）", abs(rect.center.x - 220) < 0.01,
          "center.x=\(rect.center.x)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
