import Cocoa

// 橡皮擦的验证。它是 M4-2 里唯一"不产生对象、而是删对象"的工具，行为要点有三个：
//   1. 拖拽经过的对象被抹掉
//   2. **整条拖拽合成一步撤销**（否则按一次 ⌘Z 只退回一个对象，等于撤销不可用）
//   3. 挂在被抹对象上的箭头一并抹掉（否则画布上留下吊在不存在父对象上的箭头）
// 这三条都是画布内部状态，光读代码判断不了，所以直接离屏构造一个画布、合成鼠标事件跑。
//
// 编译时链接**真实的**全部源文件（除 main.swift），测的就是要发布的那份代码。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

_ = NSApplication.shared        // 让 AppKit 就绪（不需要跑事件循环）

func makeCanvas(w: Int = 600, h: Int = 400) -> AnnotationView {
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    image.unlockFocus()
    return AnnotationView(image: image)
}

func mouse(_ type: NSEvent.EventType, _ p: CGPoint, drag: Bool = false) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                       timestamp: 0, windowNumber: 0, context: nil,
                       eventNumber: 0, clickCount: 1, pressure: 1)!
}

/// 拖一条线：down → 若干 drag → up
func drag(_ view: AnnotationView, _ points: [CGPoint]) {
    view.mouseDown(with: mouse(.leftMouseDown, points[0]))
    for p in points.dropFirst() { view.mouseDragged(with: mouse(.leftMouseDragged, p, drag: true)) }
    view.mouseUp(with: mouse(.leftMouseUp, points.last!))
}

/// 画一个矩形（用真实路径：选中矩形工具 → 拖拽）
func drawRect(_ view: AnnotationView, _ a: CGPoint, _ b: CGPoint) {
    view.currentTool = .rectangle
    drag(view, [a, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), b])
}

// MARK: - 1. 抹掉对象

print("=== 1. 拖拽经过的对象被抹掉 ===")
do {
    let view = makeCanvas()
    drawRect(view, CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200))
    check("先画出一个矩形", view.objects.count == 1, "对象数 \(view.objects.count)")
    let undoBefore = view.undoStack.count

    view.currentTool = .eraser
    // 横穿矩形中部
    drag(view, [CGPoint(x: 60, y: 150), CGPoint(x: 150, y: 150), CGPoint(x: 260, y: 150)])

    check("橡皮擦拖过之后对象被抹掉", view.objects.isEmpty, "剩余 \(view.objects.count)")
    check("z 序也同步清空了", view.zOrder.isEmpty, "zOrder \(view.zOrder.count)")
    check("只增加了 1 步撤销（整笔拖拽算一步）",
          view.undoStack.count == undoBefore + 1,
          "\(undoBefore) → \(view.undoStack.count)")
}

// MARK: - 2. 一步撤销能全部还原

print("\n=== 2. 一步撤销把这一笔抹掉的全部还原 ===")
do {
    let view = makeCanvas()
    drawRect(view, CGPoint(x: 60, y: 60), CGPoint(x: 130, y: 130))
    drawRect(view, CGPoint(x: 200, y: 60), CGPoint(x: 270, y: 130))
    drawRect(view, CGPoint(x: 340, y: 60), CGPoint(x: 410, y: 130))
    check("先画出三个矩形", view.objects.count == 3, "\(view.objects.count)")

    view.currentTool = .eraser
    let undoBefore = view.undoStack.count
    // 一笔横穿全部三个
    drag(view, [CGPoint(x: 30, y: 95), CGPoint(x: 200, y: 95), CGPoint(x: 450, y: 95)])
    check("一笔把三个都抹掉", view.objects.isEmpty, "剩余 \(view.objects.count)")
    check("仍然只有 1 步撤销", view.undoStack.count == undoBefore + 1,
          "\(undoBefore) → \(view.undoStack.count)")

    view.performUndo()
    check("一次撤销就把三个全还原", view.objects.count == 3, "还原 \(view.objects.count)")

    view.performRedo()
    check("一次重做又把三个全抹掉", view.objects.isEmpty, "剩余 \(view.objects.count)")
}

// MARK: - 3. 挂在被抹对象上的箭头一并抹掉

print("\n=== 3. 被抹对象上的箭头一并抹掉（不留悬空引用）===")
do {
    let view = makeCanvas()
    // 线宽调细：默认 15 时命中描边有 21 点宽，箭头起点会落在矩形的命中区里，
    // 于是 mouseDown 变成"拖动矩形"而不是"起笔画箭头"（我第一版就踩了这个）。
    view.currentLineWidth = 4
    drawRect(view, CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200))
    check("一个矩形", view.objects.count == 1)

    // 起点距角点约 10 点：在命中描边之外（5 点），又在吸附阈值之内（15 点）
    view.currentTool = .arrow
    drag(view, [CGPoint(x: 207, y: 207), CGPoint(x: 400, y: 350)])
    check("现在有一个矩形 + 一个箭头", view.objects.count == 2, "\(view.objects.count)")

    let arrowAttached = view.objects.values.contains { obj in
        guard let arrow = obj as? Arrow else { return false }
        return arrow.startAttachment != nil || arrow.endAttachment != nil
    }
    check("箭头确实吸附到了矩形上（否则这条用例没有意义）", arrowAttached)

    view.currentTool = .eraser
    drag(view, [CGPoint(x: 110, y: 150), CGPoint(x: 190, y: 150)])   // 抹掉矩形

    check("矩形被抹掉后箭头也不在了", view.objects.isEmpty, "剩余 \(view.objects.count)")

    view.performUndo()
    check("撤销一并还原矩形与箭头", view.objects.count == 2, "还原 \(view.objects.count)")
    let stillAttached = view.objects.values.contains { obj in
        guard let arrow = obj as? Arrow else { return false }
        return arrow.startAttachment != nil || arrow.endAttachment != nil
    }
    check("还原后附着关系还在（不是还原成两个不相干的对象）", stillAttached)
}

// MARK: - 4. 快速拖拽不漏（离散事件之间的路径要补点）

print("\n=== 4. 快速拖拽：中间没有事件的地方也要擦到 ===")
do {
    let view = makeCanvas()
    drawRect(view, CGPoint(x: 250, y: 150), CGPoint(x: 350, y: 250))
    view.currentTool = .eraser
    // 只给首尾两个点，中间隔了 300 点 —— 不补点的话会整个跳过
    drag(view, [CGPoint(x: 100, y: 200), CGPoint(x: 500, y: 200)])
    check("首尾相隔 400 点也能擦到中间的对象", view.objects.isEmpty,
          "剩余 \(view.objects.count)")
}

// MARK: - 5. 没擦到东西时不产生撤销步骤

print("\n=== 5. 空拖拽不该产生撤销步骤 ===")
do {
    let view = makeCanvas()
    drawRect(view, CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200))
    view.currentTool = .eraser
    let undoBefore = view.undoStack.count
    drag(view, [CGPoint(x: 450, y: 350), CGPoint(x: 550, y: 350)])   // 空白处
    check("空白处拖拽不增加撤销步骤", view.undoStack.count == undoBefore,
          "\(undoBefore) → \(view.undoStack.count)")
    check("原有对象没被动过", view.objects.count == 1, "\(view.objects.count)")
}

// MARK: - 6. 打码对象也能被擦掉

print("\n=== 6. 打码对象（马赛克）也能被橡皮擦掉 ===")
do {
    let view = makeCanvas()
    view.currentTool = .mosaic
    drag(view, [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250)])
    check("画出一块马赛克", view.objects.count == 1, "\(view.objects.count)")
    check("它确实是 RedactionShape",
          view.objects.values.first is RedactionShape)

    view.currentTool = .eraser
    drag(view, [CGPoint(x: 150, y: 180), CGPoint(x: 250, y: 180)])
    check("马赛克被擦掉", view.objects.isEmpty, "剩余 \(view.objects.count)")
}

// MARK: - 7. 打码形状的点击能命中（填充命中而非描边）

print("\n=== 7. 打码块整块可点中（其它形状是描边命中，它是填充命中）===")
do {
    let view = makeCanvas()
    view.currentTool = .blur
    drag(view, [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250)])
    view.currentTool = .arrow      // 切走工具，避免继续画

    // 点在块的正中间 —— 若命中判定是描边，这里会落空
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 175)))
    check("点中块中心即被选中", view.selectedKey != nil, "selected=\(String(describing: view.selectedKey))")
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 175)))
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
