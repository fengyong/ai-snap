// 撤销栈配对不变量探针（O12 步骤 0，2026-11-11）。
//
// 背景：撤销/重做是两份数据（undoStack / redoStack），而「正向变更」与「重做回推」
// **都要往 undoStack 里塞东西** —— 两边的写法不一样：
//   · 正向变更：append undo **+ 清空 redo**
//   · 重做路径：只 append undo，**绝不能碰 redo**
//
// 这条不对称今天成立，但**代码里没有任何表达**：正向变更有 10 个写点，
// 每个都手写一遍「append undo + redoStack.removeAll()」；重做路径有 8 处，
// 每个只写「undoStack.append(...)」。两边靠人手配平。
//
// 后果很具体：新人照抄正向变更的写法去改重做路径，就会顺手清掉 redo 栈 ——
// 症状是「重做只能做一次」，**静默**：不崩、不报错，只是第二次 ⇧⌘Z 没反应。
// 这类错不会被任何崩溃暴露，正是需要护栏探针的地方。
//
// O12 要把这条不变量变成**结构**（`record` / `reapply` 两个入口：正向变更清 redo、
// 重做不清 redo，在结构上没法写错）。但在动结构**之前**必须先有护栏 ——
// 这份探针就是那个护栏：它现在就把三条规则钉死，改结构时红了就知道哪条被破坏。
//
// 钉住的三条规则：
//   规则 1（清空侧）：任何正向变更之后，redo 栈必须为空。
//   规则 2（撤销侧）：performUndo 只往 redo 栈**追加**，绝不清空它。
//   规则 3（重做侧）：performRedo 只往 undo 栈**追加**，绝不碰 redo 栈。
//
// 覆盖：正向变更的 **10 个写点 / 8 类 UndoAction** 逐类核对
//   （.add / .move / .rotate / .scale / .resize / .restyle ×2 / .delete ×2 / .editText）
//   —— 与 AnnotationView.swift、AnnotationView+TextEditing.swift 里的
//   「undoStack.append + redoStack.removeAll」配对点一一对应。
//
// 状态（2026-11-11）：首次落地，全绿。
//
//      run_probe undo_pairing_probe "${ALL_SOURCES[@]}"
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

_ = NSApplication.shared

// MARK: - 事件合成

func mouse(_ type: NSEvent.EventType, _ p: CGPoint,
           flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0,
                       clickCount: 1, pressure: 1)!
}
func blankCanvas(_ w: CGFloat, _ h: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus(); NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill(); image.unlockFocus()
    return image
}
func drag(_ view: AnnotationView, _ points: [CGPoint],
          flags: NSEvent.ModifierFlags = []) {
    view.mouseDown(with: mouse(.leftMouseDown, points[0], flags: flags))
    for p in points.dropFirst() {
        view.mouseDragged(with: mouse(.leftMouseDragged, p, flags: flags))
    }
    view.mouseUp(with: mouse(.leftMouseUp, points[points.count - 1], flags: flags))
}

// MARK: - 几何夹具
//
// 目标矩形取 300×300：边角留足余量，手柄（角点 + 边中点）与吸附点（半径 12）
// 都离落点足够远，拖拽不会误触别的分支。
//  —— 坐标都是画布坐标（AnnotationView 的坐标系与 NSImage 一致，不翻转）。
enum Geo {
    static let tl = CGPoint(x: 200, y: 100)
    static let br = CGPoint(x: 500, y: 400)
    static let center = CGPoint(x: 350, y: 250)

    /// 右边框上、离角点 (500,400) 与边中点 (500,250) 都远 —— 按这里是「移动」
    static let moveGrab = CGPoint(x: 500, y: 350)
    static let moveEnd = CGPoint(x: 540, y: 370)
    /// 右边中点 = 尺寸手柄
    static let resizeGrab = CGPoint(x: 500, y: 250)
    static let resizeEnd = CGPoint(x: 530, y: 250)
    /// 缩放：bbox 内、离中心 70 点 → 放到 100 点（**放大**，绕开下限拒绝）
    static let scaleGrab = CGPoint(x: 400, y: 200)
    static let scaleEnd = CGPoint(x: 450, y: 250)
    /// 旋转：bbox 内，离中心 122 点 → 转到 76 点（≈78°）
    static let rotateGrab = CGPoint(x: 450, y: 320)
    static let rotateEnd = CGPoint(x: 320, y: 320)
    /// 橡皮擦横穿目标矩形的两条竖边
    static let erasePath = [CGPoint(x: 150, y: 250), CGPoint(x: 350, y: 250),
                            CGPoint(x: 550, y: 250)]
    /// 填充用的两个小矩形：离目标远，擦除路径也碰不到
    static let filler1 = (CGPoint(x: 600, y: 100), CGPoint(x: 700, y: 200))
    static let filler2 = (CGPoint(x: 750, y: 100), CGPoint(x: 850, y: 200))
}

func makeView() -> AnnotationView {
    AnnotationView(image: blankCanvas(1000, 700))
}

/// 画一个矩形（走真实拖拽路径 → registerNewObject → .add）
func drawRect(_ view: AnnotationView, _ a: CGPoint, _ b: CGPoint) {
    view.currentTool = .rectangle
    drag(view, [a, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), b])
}

/// 画布 + 一个目标矩形（矩形族：可移 / 可缩 / 可转 / 可调尺寸）
func makeTargetView() -> (AnnotationView, UInt32, RectangleShape) {
    let view = makeView()
    drawRect(view, Geo.tl, Geo.br)
    let key = view.zOrder.last!
    return (view, key, view.objects[key] as! RectangleShape)
}

/// 画布 + 一条**已有内容**的文字标注
/// （创建态首编不记 .editText —— 所以要先提交一次「Hello」，
///   之后的再次编辑才会被记成 .editText）
func makeTextView() -> (AnnotationView, UInt32, TextShape) {
    let view = makeView()
    view.currentTool = .text
    drag(view, [CGPoint(x: 300, y: 300)])
    let key = view.zOrder.last!
    let shape = view.objects[key] as! TextShape
    view.textEditingField?.stringValue = "Hello"
    view.endTextEditing(commit: true)
    return (view, key, shape)
}

// MARK: - 通用核对

/// 规则 1：正向变更之后，redo 栈必须为空。
///
/// 调用时**变更已经发生**，调用方把变更前后的计数传进来。
///
/// 调用前必须保证：redo 栈在变更**之前**非空，且这次变更是**紧接着的第一个
/// 正向变更** —— 否则它自己就把 redo 清了，断言会变成同义反复（永远绿，
/// 什么也测不到）。每条用例都用「画一个填充矩形再撤销它」来造出这个状态。
func checkForwardClearsRedo(_ label: String,
                            _ view: AnnotationView,
                            redoBefore: Int,
                            undoBefore: Int) {
    check("\(label)｜前置：变更前 redo 栈非空", redoBefore > 0, "redo=\(redoBefore)")
    check("\(label)｜正向变更后 redo 栈为空", view.redoStack.isEmpty,
          "redo \(redoBefore) → \(view.redoStack.count)")
    check("\(label)｜正向变更被记进 undo 栈", view.undoStack.count == undoBefore + 1,
          "undo \(undoBefore) → \(view.undoStack.count)")
}

/// 规则 3：重做不得清空 redo 栈 —— 每重做一笔，redo 栈**只少一项**。
///
/// `depth` = 撤销栈深度（被测动作之上还压着几笔）。
/// `skip`  = 重做时要先跳过几笔才轮到被测动作。
/// redo 是 LIFO：最后做的先撤、重做时最后撤的先重做 —— 所以被测动作必须是
/// **最早**做的那笔（栈底），否则第一个被重做的就不是它。
///
/// `stateOK`：重做之后状态应与「做完那一刻」一致（闭包捕获做完时的值）。
func checkRedoKeepsRest(_ label: String,
                        _ view: AnnotationView,
                        depth: Int,
                        skip: Int,
                        _ stateOK: () -> Bool) {
    for _ in 0..<depth { view.performUndo() }
    check("\(label)｜撤销到底 → redo 栈 \(depth) 项、undo 栈空",
          view.redoStack.count == depth && view.undoStack.isEmpty,
          "redo=\(view.redoStack.count) undo=\(view.undoStack.count)")
    for i in 0..<skip {
        view.performRedo()
        check("\(label)｜跳过第 \(i + 1) 笔重做后 redo 栈剩 \(depth - i - 1) 项",
              view.redoStack.count == depth - i - 1, "redo=\(view.redoStack.count)")
    }
    view.performRedo()
    check("\(label)｜重做被测动作 → redo 栈**只少一项**（没被清空）",
          view.redoStack.count == depth - skip - 1,
          "redo=\(view.redoStack.count)，期望 \(depth - skip - 1)")
    check("\(label)｜重做被测动作 → undo 栈 \(skip + 1) 项",
          view.undoStack.count == skip + 1, "undo=\(view.undoStack.count)")
    check("\(label)｜重做后状态与做完那一刻一致", stateOK())
    while view.redoStack.count > 0 { view.performRedo() }
    check("\(label)｜重做到底 → redo 栈空、undo 栈回到 \(depth) 项",
          view.redoStack.isEmpty && view.undoStack.count == depth,
          "redo=\(view.redoStack.count) undo=\(view.undoStack.count)")
}

// MARK: - 1. 撤销方向

print("=== 1. 撤销方向：performUndo 只往 redo 栈追加，绝不清空它 ===\n")
do {
    let view = makeView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    drawRect(view, Geo.filler2.0, Geo.filler2.1)
    check("前置：undo 栈 2 层", view.undoStack.count == 2, "\(view.undoStack.count)")
    view.performUndo()
    check("撤销一次 → redo 栈 1 层、undo 栈 1 层",
          view.redoStack.count == 1 && view.undoStack.count == 1,
          "redo=\(view.redoStack.count) undo=\(view.undoStack.count)")
    view.performUndo()
    check("撤销两次 → redo 栈 2 层、undo 栈空",
          view.redoStack.count == 2 && view.undoStack.isEmpty,
          "redo=\(view.redoStack.count) undo=\(view.undoStack.count)")
    view.performUndo()
    check("撤销到底后再撤销一次 → 两栈都不动（不能把 redo 清掉）",
          view.redoStack.count == 2 && view.undoStack.isEmpty,
          "redo=\(view.redoStack.count) undo=\(view.undoStack.count)")
}

// MARK: - 2. 逐类正向变更

print("\n=== 2. 每一类正向变更都必须清空 redo 栈，且重做时不得清空它 ===\n")

print("-- 2.1 .add（拖拽画一个新对象）--")
do {
    // ── 清空侧 ──
    let view = makeView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()                       // redo 栈里躺着一笔
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    drawRect(view, CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 300))
    checkForwardClearsRedo(".add", view, redoBefore: redoBefore, undoBefore: undoBefore)

    // ── 重做侧 ──
    let view2 = makeView()
    drawRect(view2, CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 300))   // 被测动作
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    // 被测动作是**最早**做的那笔 → 重做它之后画布上只有它一个对象
    // （两个填充矩形排在它后面，还没轮到重做）
    checkRedoKeepsRest(".add", view2, depth: 3, skip: 0) {
        view2.objects.count == 1
    }
}

print("\n-- 2.2 .move（拖动选中对象）--")
do {
    // ── 清空侧 ──
    let (view, key, shape) = makeTargetView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    view.selectedKey = key
    drag(view, [Geo.moveGrab, Geo.moveEnd])
    let movedCenter = shape.center
    checkForwardClearsRedo(".move", view, redoBefore: redoBefore, undoBefore: undoBefore)
    check(".move｜对象确实移动了", abs(movedCenter.x - Geo.center.x) > 0.01,
          "center=\(movedCenter)")

    // ── 重做侧 ──
    let (view2, key2, shape2) = makeTargetView()
    view2.selectedKey = key2
    drag(view2, [Geo.moveGrab, Geo.moveEnd])
    let movedCenter2 = shape2.center
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".move", view2, depth: 4, skip: 1) {
        abs(shape2.center.x - movedCenter2.x) < 0.01
            && abs(shape2.center.y - movedCenter2.y) < 0.01
    }
}

print("\n-- 2.3 .rotate（Option 拖动）--")
do {
    // ── 清空侧 ──
    let (view, key, shape) = makeTargetView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    view.selectedKey = key
    drag(view, [Geo.rotateGrab, Geo.rotateEnd], flags: [.option])
    let rotation = shape.rotation
    checkForwardClearsRedo(".rotate", view, redoBefore: redoBefore, undoBefore: undoBefore)
    check(".rotate｜对象确实转了", abs(rotation) > 0.01, "rotation=\(rotation)")

    // ── 重做侧 ──
    let (view2, key2, shape2) = makeTargetView()
    view2.selectedKey = key2
    drag(view2, [Geo.rotateGrab, Geo.rotateEnd], flags: [.option])
    let rotation2 = shape2.rotation
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".rotate", view2, depth: 4, skip: 1) {
        abs(shape2.rotation - rotation2) < 0.01
    }
}

print("\n-- 2.4 .scale（Shift 拖动）--")
do {
    // ── 清空侧 ──
    let (view, key, shape) = makeTargetView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    view.selectedKey = key
    drag(view, [Geo.scaleGrab, Geo.scaleEnd], flags: [.shift])
    let width = shape.width
    checkForwardClearsRedo(".scale", view, redoBefore: redoBefore, undoBefore: undoBefore)
    check(".scale｜对象确实被缩放了", abs(width - 300) > 0.01, "width=\(width)")

    // ── 重做侧 ──
    let (view2, key2, shape2) = makeTargetView()
    view2.selectedKey = key2
    drag(view2, [Geo.scaleGrab, Geo.scaleEnd], flags: [.shift])
    let width2 = shape2.width
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".scale", view2, depth: 4, skip: 1) {
        abs(shape2.width - width2) < 0.01
    }
}

print("\n-- 2.5 .resize（拖尺寸手柄）--")
do {
    // ── 清空侧 ──
    let (view, key, shape) = makeTargetView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    view.selectedKey = key
    drag(view, [Geo.resizeGrab, Geo.resizeEnd])
    let width = shape.width
    checkForwardClearsRedo(".resize", view, redoBefore: redoBefore, undoBefore: undoBefore)
    check(".resize｜尺寸确实变了", abs(width - 300) > 0.01, "width=\(width)")

    // ── 重做侧 ──
    let (view2, key2, shape2) = makeTargetView()
    view2.selectedKey = key2
    drag(view2, [Geo.resizeGrab, Geo.resizeEnd])
    let width2 = shape2.width
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".resize", view2, depth: 4, skip: 1) {
        abs(shape2.width - width2) < 0.01
    }
}

print("\n-- 2.6 .restyle（改颜色，restyleSelection）--")
do {
    // ── 清空侧 ──
    let (view, key, shape) = makeTargetView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    let blue = NSColor.systemBlue
    view.selectedKey = key
    let changed = view.restyleSelection(color: blue)
    check(".restyle｜restyleSelection 返回 true（确实改了）", changed)
    check(".restyle｜颜色确实变成新值", shape.color === blue, "\(shape.color)")
    checkForwardClearsRedo(".restyle", view, redoBefore: redoBefore, undoBefore: undoBefore)

    // ── 重做侧 ──
    let (view2, key2, shape2) = makeTargetView()
    let blue2 = NSColor.systemBlue
    view2.selectedKey = key2
    view2.restyleSelection(color: blue2)
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".restyle", view2, depth: 4, skip: 1) {
        shape2.color === blue2
    }
}

print("\n-- 2.7 .restyle（连续改线宽，begin/update/endContinuousRestyle）--")
do {
    // ── 清空侧 ──
    let (view, key, shape) = makeTargetView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    view.selectedKey = key
    view.beginContinuousRestyle()
    view.updateContinuousRestyle(lineWidth: 8)
    view.endContinuousRestyle()
    let lineWidth = shape.lineWidth
    check(".restyle｜线宽确实变了", abs(lineWidth - 8) < 0.01, "lineWidth=\(lineWidth)")
    checkForwardClearsRedo(".restyle", view, redoBefore: redoBefore, undoBefore: undoBefore)

    // ── 重做侧 ──
    let (view2, key2, shape2) = makeTargetView()
    view2.selectedKey = key2
    view2.beginContinuousRestyle()
    view2.updateContinuousRestyle(lineWidth: 8)
    view2.endContinuousRestyle()
    let lineWidth2 = shape2.lineWidth
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".restyle", view2, depth: 4, skip: 1) {
        abs(shape2.lineWidth - lineWidth2) < 0.01
    }
}

print("\n-- 2.8 .delete（deleteSelectedObject，删选中）--")
do {
    // ── 清空侧 ──
    let (view, key, _) = makeTargetView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    view.selectedKey = key
    view.deleteSelectedObject()
    check(".delete｜目标确实被删了", view.objects[key] == nil)
    checkForwardClearsRedo(".delete", view, redoBefore: redoBefore, undoBefore: undoBefore)

    // ── 重做侧 ──
    let (view2, key2, _) = makeTargetView()
    view2.selectedKey = key2
    view2.deleteSelectedObject()
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".delete", view2, depth: 4, skip: 1) {
        view2.objects[key2] == nil
    }
}

print("\n-- 2.9 .delete（橡皮擦整笔拖过）--")
do {
    // ── 清空侧 ──
    let (view, key, _) = makeTargetView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    view.currentTool = .eraser
    drag(view, Geo.erasePath)
    check(".erase｜目标确实被擦掉了", view.objects[key] == nil)
    checkForwardClearsRedo(".erase", view, redoBefore: redoBefore, undoBefore: undoBefore)

    // ── 重做侧 ──
    let (view2, key2, _) = makeTargetView()
    view2.currentTool = .eraser
    drag(view2, Geo.erasePath)
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".erase", view2, depth: 4, skip: 1) {
        view2.objects[key2] == nil
    }
}

print("\n-- 2.10 .editText（编辑已有文字并提交）--")
do {
    // ── 清空侧 ──
    let (view, key, shape) = makeTextView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    view.performUndo()
    let redoBefore = view.redoStack.count
    let undoBefore = view.undoStack.count
    view.beginEditingText(shape, key: key)
    view.textEditingField?.stringValue = "Hello World"
    view.endTextEditing(commit: true)
    check(".editText｜文字确实改了", shape.text == "Hello World", "\(shape.text)")
    checkForwardClearsRedo(".editText", view, redoBefore: redoBefore, undoBefore: undoBefore)

    // ── 重做侧 ──
    let (view2, key2, shape2) = makeTextView()
    view2.beginEditingText(shape2, key: key2)
    view2.textEditingField?.stringValue = "Hello World"
    view2.endTextEditing(commit: true)
    drawRect(view2, Geo.filler1.0, Geo.filler1.1)
    drawRect(view2, Geo.filler2.0, Geo.filler2.1)
    checkRedoKeepsRest(".editText", view2, depth: 4, skip: 1) {
        shape2.text == "Hello World"
    }
}

// MARK: - 3. 用户流程往返

print("\n=== 3. 用户流程：画 → 撤 → 重做 → 再画（正向变更必须掐断 redo 链）===\n")
do {
    let view = makeView()
    drawRect(view, Geo.filler1.0, Geo.filler1.1)
    drawRect(view, Geo.filler2.0, Geo.filler2.1)
    drawRect(view, CGPoint(x: 200, y: 400), CGPoint(x: 300, y: 500))
    check("画了 3 个 → undo 栈 3 层、画布 3 个对象",
          view.undoStack.count == 3 && view.objects.count == 3,
          "undo=\(view.undoStack.count) objects=\(view.objects.count)")

    view.performUndo(); view.performUndo()
    check("撤销 2 次 → redo 栈 2 层", view.redoStack.count == 2, "redo=\(view.redoStack.count)")
    view.performRedo()
    check("重做 1 次 → redo 栈 1 层（没被清空）", view.redoStack.count == 1,
          "redo=\(view.redoStack.count)")
    check("重做后画布 2 个对象", view.objects.count == 2, "objects=\(view.objects.count)")

    // 再画一个 = 正向变更 → redo 链必须被掐断
    drawRect(view, CGPoint(x: 400, y: 400), CGPoint(x: 500, y: 500))
    check("再画一个 → redo 栈被清空", view.redoStack.isEmpty, "redo=\(view.redoStack.count)")
    check("画布 3 个对象", view.objects.count == 3, "objects=\(view.objects.count)")

    while !view.undoStack.isEmpty { view.performUndo() }
    check("撤销到底 → 画布空、redo 栈 3 项",
          view.objects.isEmpty && view.redoStack.count == 3,
          "objects=\(view.objects.count) redo=\(view.redoStack.count)")
    while !view.redoStack.isEmpty { view.performRedo() }
    check("重做到底 → 画布 3 个对象、undo 栈 3 层、redo 栈空",
          view.objects.count == 3 && view.undoStack.count == 3 && view.redoStack.isEmpty,
          "objects=\(view.objects.count) undo=\(view.undoStack.count) redo=\(view.redoStack.count)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
