// 文字标注的撤销语义探针。
//
// 场景：文字工具落一个空文字 → 输入内容 → 回车提交 → 然后按 ⌘Z。
//
// 预期（用户视角）：一次 ⌘Z 应该把**刚输入的这段文字整个撤掉**。
// 实际可能：`.add`（新建对象）与 `.editText`（改文字）是两条独立记录，
// 一次 ⌘Z 只回退后者 —— 文字变回空字符串，但那个**看不见的空对象还留在画布上**，
// 要再按一次 ⌘Z 才彻底消失。而且空对象在 Layer B 上仍占一块命中区，
// 点上去会选中一片"什么都没有"。
//
// 状态（2026-11-09）：全部转绿。P1-2 以「创建态首编不单独记 .editText」修复 ——
// .add 凭实例引用带回已输入文字，undo/redo 对称；另加固 TextShape.drawHitTest
// 对空文字不画命中区（空壳物理不可选中，杀掉整类问题）。
//
//      run_probe text_undo_probe      "${ALL_SOURCES[@]}"
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

/// 落一个文字标注，返回 (view, shape)
func placeText(at p: CGPoint = CGPoint(x: 200, y: 200)) -> (AnnotationView, TextShape) {
    let view = AnnotationView(image: blankCanvas(600, 400))
    view.currentTool = .text
    view.mouseDown(with: mouse(.leftMouseDown, p))
    view.mouseUp(with: mouse(.leftMouseUp, p))
    let shape = view.objects.values.first as! TextShape
    return (view, shape)
}

/// 统计 undoStack 里各类动作
func describe(_ stack: [UndoAction]) -> String {
    var add = 0, edit = 0, other = 0
    for a in stack {
        switch a {
        case .add: add += 1
        case .editText: edit += 1
        default: other += 1
        }
    }
    return "add=\(add) editText=\(edit) other=\(other)"
}

print("=== 1. 新建文字 → 输入 → 提交 → 一次 ⌘Z 应当整个撤掉 ===\n")
do {
    let (view, shape) = placeText()
    check("前置：已落一个空文字对象", view.objects.count == 1, "objects=\(view.objects.count)")

    // 模拟输入并回车提交
    view.textEditingField?.stringValue = "Hello"
    view.endTextEditing(commit: true)
    check("提交后文字为 Hello", shape.text == "Hello", "\(shape.text)")
    // 创建态首编**不单独记 .editText**（2026-11-09 修复）：.add 凭实例引用带回
    // 已输入的文字，undo/redo 天然对称；单独记账会留下「撤不掉的空壳」中间态。
    check("撤销栈：仅 add（首编不单独记账）",
          describe(view.undoStack) == "add=1 editText=0 other=0",
          describe(view.undoStack))

    view.performUndo()
    check("一次 ⌘Z 后画布上不再有这个对象",
          view.objects.isEmpty,
          "objects=\(view.objects.count) text=\(shape.text)")

    // 再按一次看看栈是否清空
    view.performUndo()
    check("两次 ⌘Z 后撤销栈清空", view.undoStack.isEmpty,
          "stack=\(describe(view.undoStack))")
}

print("\n=== 1.5 重做往返：⌘Z 摘掉整个对象后 ⇧⌘Z 应带着文字回来 ===\n")
do {
    let (view, shape) = placeText()
    view.textEditingField?.stringValue = "Hello"
    view.endTextEditing(commit: true)
    view.performUndo()
    check("撤销后对象已摘除", view.objects.isEmpty, "objects=\(view.objects.count)")
    view.performRedo()
    check("重做后对象回来且文字仍在",
          view.objects.count == 1 && shape.text == "Hello",
          "objects=\(view.objects.count) text=\(shape.text)")
}

print("\n=== 2. 对照：空提交（什么都没输入）应当不留对象、也不留撤销记录 ===\n")
do {
    let (view, shape) = placeText()
    view.endTextEditing(commit: true)   // 空内容
    check("对象已被撤掉", view.objects.isEmpty, "objects=\(view.objects.count)")
    check("撤销栈已回退到空", view.undoStack.isEmpty, describe(view.undoStack))
}

print("\n=== 3. 对照：编辑已有文字（双击进入）一次 ⌘Z 应回退到改前 ===\n")
do {
    let (view, shape) = placeText()
    view.textEditingField?.stringValue = "Hello"
    view.endTextEditing(commit: true)

    // 再编辑一次（模拟双击进入编辑）
    view.beginEditingText(shape, key: view.objects.keys.first!)
    view.textEditingField?.stringValue = "Hello World"
    view.endTextEditing(commit: true)
    check("第二次提交后文字更新", shape.text == "Hello World", "\(shape.text)")

    view.performUndo()
    check("一次 ⌘Z 回退到 Hello", shape.text == "Hello", "\(shape.text)")
    check("对象仍在画布上", view.objects.count == 1, "objects=\(view.objects.count)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
