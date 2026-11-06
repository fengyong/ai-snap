// 选区可调整态（adjustable）的行为探针：链接真实源码 + 合成事件。
//
// 覆盖 Snipaste 式两步语义（2026-11-06，a1c6601）最容易坏的事：
//   1. 有效拖拽松手进入 adjustable 而不是立即确认（两步语义的主体）；
//   2. 选区内拖 = 整框移动（不漂移、不出屏、不误确认）；
//   3. 手柄缩放：角调两维 / 边调一维、对边锚定、最小边长钳制不翻面；
//   4. 选区外按下 = 旧框作废重选；单击（无拖拽）安静回 idle；
//   5. 方向键微调（±1 / Shift ±10）、Enter 确认、双击确认、Esc 取消；
//   6. 移动/缩放同样吸附窗口边（8b69580），与 dragging 创建阶段同一通路。
// 断言锚在 pendingAdjustmentRect（状态本身）与最终回调的矩形上 ——
// 离屏环境里 needsDisplay 不可观测（实测设 true 读回 false），不拿它当断言。
//
// 前身是 9da6f7b 删掉的 selection_adjust_probe（只覆盖「待确认 + 微调」），
// 本次随功能一起重写：移动/缩放/重选/吸附都是新断言。
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
var interactionStarts = 0
view.onSelectionComplete = { completed = $0 }
view.onCancel = { cancelled = true }
view.onInteractionStart = { interactionStarts += 1 }

print("=== 1. 拖拽松手 → adjustable（不立即确认）===\n")
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 220, y: 280)))
check("拖拽中不在 adjustable 族态、也未确认",
      view.pendingAdjustmentRect == nil && completed == nil,
      "\(String(describing: view.pendingAdjustmentRect))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 220, y: 280)))
check("松手进入 adjustable 态", view.pendingAdjustmentRect != nil,
      "\(String(describing: view.pendingAdjustmentRect))")
check("尚未回调确认", completed == nil)
check("mouseDown 触发 onInteractionStart", interactionStarts == 1)

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
check("adjustable 态清空", view.pendingAdjustmentRect == nil)
check("回调拿到微调后的矩形", completed == NSRect(x: 110, y: 100, width: 120, height: 180),
      "\(String(describing: completed))")

print("\n=== 4. 双击确认（第一击进 adjustable、第二击即确认）===\n")
completed = nil
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 150, y: 150)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 150)))
check("第一击松手后进入 adjustable", view.pendingAdjustmentRect != nil)
// 第二击 clickCount == 2，落在 adjustable 态且点在选区**内部** → 确认而不是开始新拖拽。
// （边界点不算「内部」：NSRect.contains 对 max 边开区间，边界属于手柄调整区。）
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 120, y: 120), clickCount: 2))
check("双击确认回调", completed == NSRect(x: 50, y: 50, width: 100, height: 100),
      "\(String(describing: completed))")
check("双击后没有残留 adjustable 矩形", view.pendingAdjustmentRect == nil)

print("\n=== 5. 太小的拖拽被拒、可重拖 ===\n")
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 10)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 12, y: 12)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 12, y: 12)))
check("太小的拖拽不进入 adjustable", view.pendingAdjustmentRect == nil)
check("太小的拖拽不确认", completed == NSRect(x: 50, y: 50, width: 100, height: 100))
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 300)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 400, y: 380)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 380)))
check("重拖后回到 adjustable", view.pendingAdjustmentRect == NSRect(x: 300, y: 300, width: 100, height: 80))

print("\n=== 6. 选区内拖动 = 整框移动（不确认、不漂移）===\n")
completed = nil
// adjustable 矩形 (300,300,100,80)，中心 (350,340)
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 350, y: 340)))
check("选区内按下进入移动而非重选", view.pendingAdjustmentRect == NSRect(x: 300, y: 300, width: 100, height: 80))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 383, y: 355)))
check("移动按位移增量平移（+33,+15）",
      view.pendingAdjustmentRect == NSRect(x: 333, y: 315, width: 100, height: 80),
      "\(String(describing: view.pendingAdjustmentRect))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 383, y: 355)))
check("移动松手回到 adjustable", view.pendingAdjustmentRect == NSRect(x: 333, y: 315, width: 100, height: 80))
check("移动不触发确认", completed == nil)

print("\n=== 7. 移动钳在屏内（不出屏）===\n")
// 从 (333,315,100,80) 向左下死拖 —— 原点必须被钳回 (0,0)
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 383, y: 355)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: -500, y: -600)))
check("移出屏的原点被钳回屏内", view.pendingAdjustmentRect == NSRect(x: 0, y: 0, width: 100, height: 80),
      "\(String(describing: view.pendingAdjustmentRect))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: -500, y: -600)))

print("\n=== 8. 手柄缩放：角调两维、对边锚定 ===\n")
// 新选区 (100,100,200,200)，右下角手柄锚点 (300,100)
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 500, y: 500)))   // 选区外 → 重选
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 100, y: 100)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 100)))
check("重选出新 adjustable 矩形", view.pendingAdjustmentRect == NSRect(x: 100, y: 100, width: 400, height: 400),
      "\(String(describing: view.pendingAdjustmentRect))")
// 贴着右下角 (500,100) 按下（角 ±6pt 内）拖到 (560,240)：maxX 跟随到 560，
// 底边（minY）从 100 跟到 240（y 向上，拖「右下角」向上 = 底边上收）
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 500, y: 100)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 560, y: 240)))
check("拖右下角：minX 锚定，maxX/minY 跟随光标",
      view.pendingAdjustmentRect == NSRect(x: 100, y: 240, width: 460, height: 260),
      "\(String(describing: view.pendingAdjustmentRect))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 560, y: 240)))
check("缩放松手仍在 adjustable", view.pendingAdjustmentRect != nil && completed == nil)

print("\n=== 9. 手柄缩放：拖过对边不翻面（最小边 5pt）===\n")
// 从 (100,240,460,260) 抓右下角 (560,240)，向左上死拖越过高 500 的对边
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 560, y: 240)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: -300, y: 560)))
check("越过对边被钉在 minSide=5（两维都不翻面）",
      view.pendingAdjustmentRect == NSRect(x: 100, y: 495, width: 5, height: 5),
      "\(String(describing: view.pendingAdjustmentRect))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: -300, y: 560)))

print("\n=== 10. 手柄缩放：边手柄只动一维 ===\n")
// 新选区 (200,200,250,250)，左边带中点 (200,300) 按下向左拖
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 450, y: 450)))   // 重选
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 200, y: 200)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 200)))
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 300)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 150, y: 330)))
check("拖左边：宽度变、高度不变（y 位移不影响）",
      view.pendingAdjustmentRect == NSRect(x: 150, y: 200, width: 300, height: 250),
      "\(String(describing: view.pendingAdjustmentRect))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 330)))

print("\n=== 11. 单击（无拖拽）安静回 idle ===\n")
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 500, y: 500)))   // 选区外单击
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 500, y: 500)))
check("单击不清 adjustable（此前已重选为 idle）……此处应无矩形",
      view.pendingAdjustmentRect == nil && completed == nil && !cancelled)

print("\n=== 12. 移动吸附窗口边 ===\n")
// 吸附目标：全局坐标下的窗口框（screenOrigin 默认 .zero，视图坐标即全局）
view.snapTargets = [CGRect(x: 40, y: 380, width: 120, height: 80)]
// 造一个选区 (250,50,100,80)，四周离窗口框都很远，创建阶段不触发吸附
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 350, y: 50)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 250, y: 130)))
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 250, y: 130)))
let before = view.pendingAdjustmentRect
check("造出移动起点选区", before == NSRect(x: 250, y: 50, width: 100, height: 80),
      "\(String(describing: before))")
// 从中心 (300,90) 拖到 (94,90)：minX 落在 44，距窗口左边 40 差 4pt ≤ 8 阈值 → 贴到 40。
// 吸附逐边独立决策：maxX=144 距窗口边都超阈值保持不动，宽度因此 +4 ——
// 与 dragging 创建阶段是同一套 SelectionSnapping 语义，不是缺陷。
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 90)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 94, y: 90)))
check("移动中左边贴上窗口边（未贴的边不动、宽度 +4）",
      view.pendingAdjustmentRect == NSRect(x: 40, y: 50, width: 104, height: 80),
      "\(String(describing: view.pendingAdjustmentRect))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 94, y: 90)))
view.snapTargets = []

print("\n=== 13. 缩放吸附窗口边 ===\n")
// 选区 (40,50,100,80)，拖右边（maxX=140）到 156 → 距窗口右边 160 差 4pt ≤ 8 → 贴上 160
view.snapTargets = [CGRect(x: 40, y: 380, width: 120, height: 80)]
view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 140, y: 90)))
view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 156, y: 90)))
check("缩放中右边贴上窗口边",
      view.pendingAdjustmentRect == NSRect(x: 40, y: 50, width: 120, height: 80),
      "\(String(describing: view.pendingAdjustmentRect))")
view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 156, y: 90)))
view.snapTargets = []

print("\n=== 14. adjustable 态里 Esc 取消（不确认）===\n")
completed = nil
view.keyDown(with: key(53))
check("Esc 触发取消回调", cancelled)
check("Esc 后没有确认回调", completed == nil)
check("Esc 后 adjustable 清空", view.pendingAdjustmentRect == nil)

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
