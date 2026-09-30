// 聚光灯（矩形族）边/角手柄调整大小的行为探针：链接真实源码 + 合成鼠标事件。
//
// 修的是「聚光灯选中后只能 Shift 等比缩放、调不到单边」：高亮区域要精确罩住
// 一段内容，宽高必须能独立调。手柄语义：拖边 = 单维（对边锚定不动）、
// 拖角 = 双维（对角锚定不动）、Esc 中途取消完整还原、撤销还原。
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
    // 点右边框选中（Esc 先退出画完后的状态）。
    // 注意聚光灯的命中是**描边**（中心是挖空的洞，点中心选不中）；
    // 边框同时是吸附点 —— 这条路径顺带验证「吸附点上点击 = 选中」。
    view.keyDown(with: key(53))
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 200)))
    return (view, spot)
}

print("=== 1. 拖右边手柄：只改宽，左边锚定不动 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    check("前置：200×200 聚光灯已选中",
          abs(spot.width - 200) < 0.01 && abs(spot.height - 200) < 0.01
          && view.selectedKey != nil,
          "w=\(spot.width) h=\(spot.height)")

    // 右边手柄在 (400, 200)；向右拖 30 → 宽 +30，左边 x=200 不动
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 430, y: 205)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 430, y: 205)))

    check("宽 +30（200 → 230）", abs(spot.width - 230) < 0.01, "\(spot.width)")
    check("高不变（单维调整）", abs(spot.height - 200) < 0.01, "\(spot.height)")
    check("左边锚定（center.x = 315 = 300 + 15，左边 200 不动）", abs(spot.center.x - 315) < 0.01,
          "\(spot.center.x)")
    check("center.y 不动", abs(spot.center.y - 200) < 0.01, "\(spot.center.y)")

    // 撤销完整还原
    view.performUndo()
    check("⌘Z 还原宽高", abs(spot.width - 200) < 0.01 && abs(spot.height - 200) < 0.01)
}

print("\n=== 2. 拖角手柄：两维同时调，对角锚定 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    // 右下角手柄 (400, 100)：AppKit y 向下？不 —— 局部 +y 是上。右下角 = (400, 100)。
    // 向右下拉到 (450, 60)：宽 +50，高 +40；锚定对角 = 左上 (200, 300)
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 100)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 450, y: 60)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 450, y: 60)))
    check("宽 +50（200 → 250）", abs(spot.width - 250) < 0.01, "\(spot.width)")
    check("高 +40（200 → 240）", abs(spot.height - 240) < 0.01, "\(spot.height)")
    // 锚定角 (200,300) 不动 → 新中心 = (200+450, 300+60)/2 = (325, 180)
    check("对角锚定（center = 325, 180）",
          abs(spot.center.x - 325) < 0.01 && abs(spot.center.y - 180) < 0.01,
          "\(spot.center)")
}

print("\n=== 3. 拖上边手柄：只改高 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    // 上边手柄 (300, 300)：向上拖 20 → 高 +20
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 300)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 320)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 320)))
    check("高 +20（200 → 220）", abs(spot.height - 220) < 0.01, "\(spot.height)")
    check("宽不变", abs(spot.width - 200) < 0.01, "\(spot.width)")
}

print("\n=== 4. Esc 中途取消：完整还原（含中心）===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    let c0 = spot.center
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 460, y: 200)))
    view.keyDown(with: key(53))   // Esc：取消，不留撤销记录
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 460, y: 200)))
    check("尺寸还原", abs(spot.width - 200) < 0.01 && abs(spot.height - 200) < 0.01,
          "w=\(spot.width) h=\(spot.height)")
    check("中心还原", spot.center == c0, "\(spot.center) vs \(c0)")
    check("没有撤销记录（取消 ≠ 一次操作）", view.undoStack.isEmpty
          || !view.undoStack.contains { undo in
              if case .resize = undo { return true }
              return false
          })
}

print("\n=== 5. 下限保护：拖过对边也不会缩成负/零 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 200)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 20, y: 200)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 20, y: 200)))
    check("宽度夹在下限之上", spot.width >= SpotlightShape.minimumExtent,
          "\(spot.width)")
    check("高度不受牵连", abs(spot.height - 200) < 0.01, "\(spot.height)")
}

print("\n=== 6. 矩形同样支持（同一协议路径）===\n")
do {
    let view = AnnotationView(image: blankCanvas(600, 400))
    view.currentTool = .rectangle
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 250)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 250)))
    view.keyDown(with: key(53))
    // 矩形命中同样是描边：点右边框 (300, 175) 选中
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 175)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 175)))
    guard let rect = view.objects.values.first as? RectangleShape else {
        check("能取到矩形", false); exit(1)
    }
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 175)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 340, y: 175)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 340, y: 175)))
    check("矩形右边手柄：宽 +40", abs(rect.width - 240) < 0.01, "\(rect.width)")
    check("高不变", abs(rect.height - 150) < 0.01, "\(rect.height)")
}

print("\n=== 7. 回归：Shift 拖拽等比缩放仍可用 ===\n")
do {
    let (view, spot) = makeSelectedSpotlight()
    // Shift 缩放的距离基准是「落点到中心的距离」—— 按在正中心距离为 0，进不了缩放态，
    // 必须按在 bbox 内的偏心位置
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 360, y: 160), flags: [.shift]))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 430, y: 230), flags: [.shift]))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 430, y: 230), flags: [.shift]))
    check("等比放大生效（两维同变）", spot.width > 200 && spot.height > 200,
          "w=\(spot.width) h=\(spot.height)")
    check("两维等比（±10%）",
          abs(spot.width / spot.height - 1.0) < 0.1,
          "比 \(spot.width / spot.height)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
