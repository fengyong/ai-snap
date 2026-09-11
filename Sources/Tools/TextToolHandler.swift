import Cocoa

/// 文字标注工具。
///
/// 放置逻辑很简单（造一个空的 `TextShape`），真正的工作在画布那侧：
/// 见 `AnnotationView+TextEditing.swift` —— 放置后会立刻叠一个 `NSTextField`
/// 让用户直接打字。
struct TextToolHandler: AnnotationToolHandler {

    /// 默认字号。**刻意不跟线宽走**：文字没有「线宽」这个概念，
    /// 当前线宽默认是 15，跟着走会得到一个巨大的字。
    /// 之后想调大小用选择框的缩放手柄（缩放作用在字号上）。
    static let defaultFontSize: CGFloat = 20

    func handles(_ tool: DrawingTool) -> Bool {
        tool == .text
    }

    func placeObject(at point: CGPoint, tool: DrawingTool,
                     context: ToolContext) -> (any AnnotationObject)? {
        TextShape(center: point,
                  text: "",                     // 空文字 → 画布会立刻进入编辑态
                  fontSize: Self.defaultFontSize,
                  color: context.color,
                  hitTestColorKey: context.colorKey)
    }
}
