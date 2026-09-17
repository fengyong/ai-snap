import Cocoa

//  驱动 AnnotationView 的合成事件辅助（需要链接 AnnotationView.swift）
//
//  用真实的 NSEvent + 真实的 mouseDown/mouseDragged/mouseUp 走生产代码路径，
//  因此可以黑盒验证命中检测、撤销重做、吸附、附着等行为。

func mouseEvent(_ type: NSEvent.EventType,
                _ point: CGPoint,
                _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type,
                       location: NSPoint(x: point.x, y: point.y),
                       modifierFlags: flags,
                       timestamp: 0,
                       windowNumber: 0,
                       context: nil,
                       eventNumber: 0,
                       clickCount: 1,
                       pressure: 1)!
}

func drag(_ view: AnnotationView,
          from a: CGPoint, to b: CGPoint,
          _ flags: NSEvent.ModifierFlags = []) {
    view.mouseDown(with: mouseEvent(.leftMouseDown, a, flags))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, b, flags))
    view.mouseUp(with: mouseEvent(.leftMouseUp, b, flags))
}

func click(_ view: AnnotationView, at p: CGPoint) {
    view.mouseDown(with: mouseEvent(.leftMouseDown, p))
    view.mouseUp(with: mouseEvent(.leftMouseUp, p))
}

func pressDelete(_ view: AnnotationView) {
    view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil,
                                        characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: 51)!)
}

func pressKey(_ view: AnnotationView, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) {
    view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil,
                                        characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: keyCode)!)
}

/// 新建一块探针画布（线宽固定 15，与 App 默认一致）
func newCanvas(_ width: CGFloat = 500, _ height: CGFloat = 400) -> AnnotationView {
    let view = AnnotationView(image: blankCanvas(width, height))
    view.currentLineWidth = 15
    return view
}

/// 判断某个位置当前是否能选中对象（返回是否为非 nil 的选中 key）
///
/// 注意：这里用 ESC 清空选中，而不是"在空白处点一下"——
/// 后者在贴纸工具下会真的放下一个贴纸，从而污染撤销栈（第一版探针就踩了这个坑）。
func selects(_ view: AnnotationView, at p: CGPoint) -> Bool {
    pressKey(view, keyCode: 53)          // ESC → 取消选中，回到绘制模式
    click(view, at: p)
    return view.selectedKey != nil
}
