// 撤销语义探针：.resize / .scale / .move 三类变换的「撤销是否完整还原」。
//
// 动机：resize_handle_probe 断言了「⌘Z 还原宽高」，但**没有断言中心是否还原**。
// 而拖边/拖角手柄在改尺寸的同时**也会移动中心**（锚点模型：中心 = 新包围盒中心）。
// UndoAction.resize 只带 oldSize/newSize，没有带中心 —— 于是撤销后尺寸回来了、
// 位置还留在拖拽后的地方，对象"跳"了一格。
//
// 这里把三条变换路径的撤销都钉一遍：resize（会移动中心）、scale（乘性可逆）、
// move（带附着还原）。
//
// ⚠️ **本探针当前是失败的**（断言的是「应该怎样」，代码还没改）。
//    它**故意没有**注册进 probes/run_all.sh —— 注册进去会让整套回归变红。
//    修好之后（UndoAction.resize 带上中心、scale 记录实际生效的倍率、
//    .editText 撤销时清掉空文字对象）再把下面这行加回 run_all.sh：
//
//      run_probe resize_undo_probe    "${ALL_SOURCES[@]}"
//      run_probe text_undo_probe      "${ALL_SOURCES[@]}"
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

/// 画一个聚光灯并点一下选中（真实事件路径）
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

print("=== 1. 拖右边手柄后撤销：尺寸 + 中心都必须还原 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    let c0 = spot.center
    let w0 = spot.width, h0 = spot.height
    check("前置：200×200 聚光灯，中心 (300,200)",
          abs(w0 - 200) < 0.01 && abs(h0 - 200) < 0.01 && abs(c0.x - 300) < 0.01,
          "w=\(w0) h=\(h0) c=\(c0)")

    // 右边手柄在 (400, 200)；向右拖 30 → 宽 230，左边锚定 → center.x = 315
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 430, y: 205)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 430, y: 205)))

    check("拖拽后宽 +30", abs(spot.width - 230) < 0.01, "\(spot.width)")
    check("拖拽后中心右移（锚点模型：中心会动）",
          abs(spot.center.x - 315) < 0.01, "center.x=\(spot.center.x)")

    view.performUndo()
    check("撤销后宽高还原", abs(spot.width - w0) < 0.01 && abs(spot.height - h0) < 0.01,
          "w=\(spot.width) h=\(spot.height)")
    check("撤销后中心还原（← 这条是本次要钉的）",
          abs(spot.center.x - c0.x) < 0.01 && abs(spot.center.y - c0.y) < 0.01,
          "center=\(spot.center) 期望 \(c0)")

    view.performRedo()
    check("重做后宽高还原", abs(spot.width - 230) < 0.01, "\(spot.width)")
    check("重做后中心还原", abs(spot.center.x - 315) < 0.01, "center.x=\(spot.center.x)")
}

print("\n=== 2. 拖角手柄后撤销：中心同样必须还原 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    let c0 = spot.center
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 100)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 450, y: 60)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 450, y: 60)))
    check("拖拽后中心变化", abs(spot.center.x - c0.x) > 0.01, "\(spot.center)")

    view.performUndo()
    check("撤销后中心还原",
          abs(spot.center.x - c0.x) < 0.01 && abs(spot.center.y - c0.y) < 0.01,
          "center=\(spot.center) 期望 \(c0)")
    check("撤销后尺寸还原", abs(spot.width - 200) < 0.01 && abs(spot.height - 200) < 0.01,
          "w=\(spot.width) h=\(spot.height)")
}

print("\n=== 3. 矩形族同样受影响（同一协议路径）===\n")
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
    let c0 = rect.center
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 175)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 340, y: 175)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 340, y: 175)))
    check("拖拽后中心变化", abs(rect.center.x - c0.x) > 0.01, "\(rect.center)")

    view.performUndo()
    check("撤销后中心还原",
          abs(rect.center.x - c0.x) < 0.01 && abs(rect.center.y - c0.y) < 0.01,
          "center=\(rect.center) 期望 \(c0)")
}

print("\n=== 4. 回归：.move 撤销仍应完整（含中心）===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    let c0 = spot.center
    // 必须抓在**不是手柄**的位置：矩形族一旦选中，边中点与角点都是 resize 手柄，
    // 按在那里会进入 .resizing 而不是 .moving。右边框 (400, 240) 离两个手柄都 > 8pt。
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 240)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 430, y: 260)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 430, y: 260)))
    check("移动生效（不是缩放）", abs(spot.center.x - c0.x) > 0.01, "\(spot.center)")
    check("移动不改尺寸", abs(spot.width - 200) < 0.01, "w=\(spot.width)")
    view.performUndo()
    check("撤销后中心还原",
          abs(spot.center.x - c0.x) < 0.01 && abs(spot.center.y - c0.y) < 0.01,
          "center=\(spot.center) 期望 \(c0)")
}

print("\n=== 5. 回归：.scale 撤销应还原尺寸与中心 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    let c0 = spot.center
    let w0 = spot.width
    // Shift + 拖 = 等比缩放；落点必须在 bbox 内且离中心 > 1
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 360, y: 160), flags: [.shift]))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 430, y: 230), flags: [.shift]))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 430, y: 230), flags: [.shift]))
    check("缩放生效", abs(spot.width - w0) > 0.01, "w=\(spot.width)")
    view.performUndo()
    check("撤销后宽高还原", abs(spot.width - w0) < 0.01, "w=\(spot.width)")
    check("撤销后中心还原",
          abs(spot.center.x - c0.x) < 0.01 && abs(spot.center.y - c0.y) < 0.01,
          "center=\(spot.center) 期望 \(c0)")
}

print("\n=== 6. .scale 撤销在「缩到下限被夹住」时会过冲 ===\n")
do {
    // 单独造一个更大的聚光灯：Shift 缩放要求落点在 bbox 内，
    // 而要拿到足够小的倍率就得让「落点到中心的距离」相对初始距离足够小。
    let view = AnnotationView(image: blankCanvas(900, 600))
    view.currentTool = .spotlight
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 200)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 400, y: 400)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 400)))
    guard let spot = view.objects.values.first as? SpotlightShape else {
        check("能取到聚光灯", false); exit(1)
    }
    view.keyDown(with: key(53))
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 402, y: 300)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 402, y: 300)))
    let w0 = spot.width
    check("前置：宽 200", abs(w0 - 200) < 0.01, "\(w0)")

    // Shift 缩放：落点距中心 102 → 1.02，倍率 0.01 → 宽被夹到下限 4
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 402, y: 300), flags: [.shift]))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 301.02, y: 300), flags: [.shift]))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 301.02, y: 300), flags: [.shift]))
    check("缩到下限 4", abs(spot.width - 4) < 0.01, "\(spot.width)")

    view.performUndo()
    check("撤销后应还原到 200（实际会过冲到 400）",
          abs(spot.width - w0) < 0.01, "w=\(spot.width) 期望 \(w0)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}