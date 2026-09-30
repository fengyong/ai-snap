// 吸附优先（落笔 vs 移动）的行为探针：链接真实源码 + 合成鼠标事件。
//
// 修的是「吸附指示与对象命中的优先级冲突」：箭头工具悬停序号圆心时，
// 吸附指示器画了"从这里起笔"的标记，按下却命中对象进了移动模式 ——
// 指示器成了谎言。修复后：拖拽绘制类工具在吸附点激活时落笔优先画画；
// ⌘ 强制移动（逃生舱）；远离吸附点踩在对象上仍移动；放置类工具不变。
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
/// 放一个序号徽章并退出选中态（模拟"画完序号再画箭头"的真实流程）
func placeBadge(at p: CGPoint) -> AnnotationView {
    let view = AnnotationView(image: blankCanvas(400, 300))
    view.currentTool = .step
    view.mouseDown(with: mouse(.leftMouseDown, p))
    view.mouseUp(with: mouse(.leftMouseUp, p))
    // 放置后处于选中态；Esc 回到绘制模式（与真实操作一致）
    view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: 53)!)
    return view
}

print("=== 1. 箭头工具落在序号圆心 → 起笔画箭头，不移动序号 ===\n")
do {
    let view = placeBadge(at: CGPoint(x: 200, y: 150))
    check("前置：画布上有一个序号", view.objects.count == 1)
    view.currentTool = .arrow
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 150)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 320, y: 220)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 320, y: 220)))

    check("新增了 1 个对象（箭头），共 2 个", view.objects.count == 2,
          "\(view.objects.count)")
    guard let badge = view.objects.values.first(where: { $0 is StepBadge }),
          let arrow = view.objects.values.first(where: { $0 is Arrow }) as? Arrow else {
        check("能取到序号与箭头", false); exit(1)
    }
    check("序号没被挪动", badge.center == CGPoint(x: 200, y: 150), "\(badge.center)")
    check("箭头起点 = 序号圆心", arrow.startPoint == CGPoint(x: 200, y: 150),
          "\(arrow.startPoint)")
    check("箭头终点 = 拖拽终点", arrow.endPoint == CGPoint(x: 320, y: 220))
}

print("\n=== 2. ⌘ + 落笔 = 强制移动（逃生舱）===\n")
do {
    let view = placeBadge(at: CGPoint(x: 200, y: 150))
    view.currentTool = .arrow
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 150), flags: [.command]))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 280, y: 180), flags: [.command]))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 280, y: 180), flags: [.command]))

    check("没有新对象（进入的是移动）", view.objects.count == 1, "\(view.objects.count)")
    if let badge = view.objects.values.first as? StepBadge {
        check("序号被挪到了新位置", badge.center == CGPoint(x: 280, y: 180),
              "\(badge.center)")
    } else {
        check("画布上还是序号", false)
    }
}

print("\n=== 3. 远离吸附点踩在对象上 → 仍是移动（行为不变）===\n")
do {
    let view = AnnotationView(image: blankCanvas(400, 300))
    view.currentTool = .rectangle
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 350, y: 250)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 350, y: 250)))
    check("前置：有一个大矩形", view.objects.count == 1)
    view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: 53)!)

    // 左边缘 (50, 210)：距边中点 (50,150) 60pt、距角点 (50,250) 40pt，都超出吸附阈值
    view.currentTool = .arrow
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 210)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 80, y: 230)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 80, y: 230)))
    check("没有新对象（移动的是矩形）", view.objects.count == 1, "\(view.objects.count)")
    if let rect = view.objects.values.first as? RectangleShape {
        check("矩形被挪动", rect.center != CGPoint(x: 200, y: 150), "\(rect.center)")
    }
}

print("\n=== 4. 放置类工具不受影响（点谁还是动谁）===\n")
do {
    let view = placeBadge(at: CGPoint(x: 120, y: 120))
    view.currentTool = .step
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 120, y: 120)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 220, y: 120)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 220, y: 120)))
    check("序号工具按在序号上：仍是移动", view.objects.count == 1
          && view.objects.values.first?.center == CGPoint(x: 220, y: 120),
          "\(view.objects.values.first?.center ?? .zero)")
}

print("\n=== 5. 手绘工具同样吸附优先 ===\n")
do {
    let view = placeBadge(at: CGPoint(x: 200, y: 150))
    view.currentTool = .pen
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 150)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 260, y: 180)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 260, y: 180)))
    check("画笔从序号圆心起笔（2 个对象，序号未动）",
          view.objects.count == 2
          && view.objects.values.first(where: { $0 is StepBadge })?.center == CGPoint(x: 200, y: 150))
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
