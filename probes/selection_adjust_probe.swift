// 选区微调（adjusting 态）的行为探针：链接真实源码 + 合成事件。
//
// 覆盖的是「松手即确认」改成「待确认可微调」之后最容易坏的三件事：
//   1. 有效拖拽进入待确认而不是立即确认；
//   2. 方向键挪整框（±1px / Shift ±10px）、Enter 确认、双击确认；
//   3. 太小的拖拽被拒后回到空闲，可以重拖。
// 断言锚在 pendingAdjustmentRect（状态本身）与最终回调的矩形上 ——
// 离屏环境里 needsDisplay 不可观测（实测设 true 读回 false），不拿它当断言。
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
           flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0,
                       clickCount: clickCount, pressure: 1)!
}
func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    // 注意 keyEvent(with:) 没有 eventNumber 参数（mouseEvent 才有）
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: 0, context: nil,
                     characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                     keyCode: code)!
}

let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
var completed: NSRect?
var cancelled = false
view.onSelectionComplete = { completed = $0 }
view.onCancel = { cancelled = true }

print("=== 1. 拖拽 → 待确认（不立即确认）===\n")
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 220, y: 280)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 220, y: 280)))
check("进入待确认态", view.pendingAdjustmentRect != nil,
      "\(String(describing: view.pendingAdjustmentRect))")
check("尚未回调确认", completed == nil)

print("\n=== 2. 方向键微调 ===\n")
view.keyDown(with: key(124))   // → +1
check("右方向键 +1px", view.pendingAdjustmentRect?.minX == 101,
      "\(view.pendingAdjustmentRect?.minX ?? -1)")
view.keyDown(with: key(123))   // ← -1
check("左方向键 -1px", view.pendingAdjustmentRect?.minX == 100)
view.keyDown(with: key(126))   // ↑ +1
check("上方向键 y +1（AppKit y 向上）", view.pendingAdjustmentRect?.minY == 101,
      "\(view.pendingAdjustmentRect?.minY ?? -1)")
view.keyDown(with: key(125))   // ↓ -1
check("下方向键 y -1", view.pendingAdjustmentRect?.minY == 100)
view.keyDown(with: key(124, flags: .shift))   // Shift+→ +10
check("Shift+右 +10px", view.pendingAdjustmentRect?.minX == 110)
check("微调只动原点、尺寸不变",
      view.pendingAdjustmentRect?.width == 120 && view.pendingAdjustmentRect?.height == 180)

print("\n=== 3. Enter 确认 ===\n")
view.keyDown(with: key(36))
check("待确认态清空", view.pendingAdjustmentRect == nil)
check("回调拿到微调后的矩形", completed == NSRect(x: 110, y: 100, width: 120, height: 180),
      "\(String(describing: completed))")

print("\n=== 4. 双击确认 ===\n")
completed = nil
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 150, y: 150)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 150)))
check("第一击后进入待确认", view.pendingAdjustmentRect != nil)
// 第二击 clickCount == 2，落在待确认态 → 确认而不是开始新拖拽
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 150), clickCount: 2))
check("双击确认回调", completed == NSRect(x: 50, y: 50, width: 100, height: 100),
      "\(String(describing: completed))")
check("双击后没有残留待确认矩形", view.pendingAdjustmentRect == nil)

print("\n=== 5. 太小的拖拽被拒、可重拖 ===\n")
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 10)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 12, y: 12)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 12, y: 12)))
check("太小的拖拽不进入待确认", view.pendingAdjustmentRect == nil)
check("太小的拖拽不确认", completed == NSRect(x: 50, y: 50, width: 100, height: 100))
// 重拖正常进入待确认
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 300)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 400, y: 380)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 380)))
check("重拖后回到待确认", view.pendingAdjustmentRect == NSRect(x: 300, y: 300, width: 100, height: 80))

print("\n=== 6. 待确认态里 Esc 取消（不确认）===\n")
completed = nil
view.keyDown(with: key(53))
check("Esc 触发取消回调", cancelled)
check("Esc 后没有确认回调", completed == nil)
check("Esc 后待确认清空", view.pendingAdjustmentRect == nil)

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
