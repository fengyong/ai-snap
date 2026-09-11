import Cocoa

/// 马赛克与高斯模糊：拖拽框选一块区域打码。
///
/// 两者共用一个 handler —— 它们是同一个形状类（`RedactionShape`），只差 `style`。
/// 与「圆角矩形复用 `RectangleShape`」是同一个取舍。
///
/// **橡皮擦不在这里**：它不是"拖拽构造一个对象"，而是一边拖一边删，需要自己的画布
/// 状态（整条拖拽路径合并成一步撤销）。把它硬塞进这个协议只会得到一个所有方法都
/// 返回 nil 的 handler，实现在别处 —— 那不如直说。见 `AnnotationView` 的 `.erasing`。
struct RedactionToolHandler: AnnotationToolHandler {

    func handles(_ tool: DrawingTool) -> Bool {
        tool == .mosaic || tool == .blur
    }

    func makeObject(from start: CGPoint, to end: CGPoint,
                    tool: DrawingTool, context: ToolContext) -> (any AnnotationObject)? {
        guard let style = style(for: tool) else { return nil }
        let shape: RedactionShape
        if context.drawingFromCenter {
            shape = RedactionShape(center: start,
                                   width: max(abs(end.x - start.x) * 2, 6),
                                   height: max(abs(end.y - start.y) * 2, 6),
                                   style: style,
                                   hitTestColorKey: context.colorKey)
        } else {
            shape = RedactionShape(from: start, to: end,
                                   style: style,
                                   hitTestColorKey: context.colorKey)
        }
        shape.sourceImage = context.sourceImage
        shape.pixelScale = context.pixelScale
        return shape
    }

    func drawPreview(from start: CGPoint, to end: CGPoint,
                     tool: DrawingTool, in ctx: CGContext, context: ToolContext) {
        guard let style = style(for: tool) else { return }
        // 预览就按最终效果画（同一套渲染路径），所见即所得。
        // 代价是每帧重算一次打码 —— 但这正是缓存键里带矩形尺寸的原因：
        // 尺寸不变时（拖拽停止后）直接命中缓存，不会反复算。
        let preview = RedactionShape(from: start, to: end,
                                     style: style, hitTestColorKey: 0)
        preview.sourceImage = context.sourceImage
        preview.pixelScale = context.pixelScale
        preview.draw(in: ctx)
    }

    /// 打码强度。暂时固定，不给 UI 入口 —— 12 点的块/半径已经足以让屏幕上的
    /// 正文和数字无法辨认，而多一个滑块就多一个要持久化、要在帮助里解释的东西。
    /// 将来若需要，把这两个常量接到工具栏的一个「强度」滑块上即可。
    static let mosaicBlockSize: CGFloat = 12
    static let blurRadius: CGFloat = 12

    private func style(for tool: DrawingTool) -> RedactionStyle? {
        switch tool {
        case .mosaic: return .mosaic(blockSize: Self.mosaicBlockSize)
        case .blur:   return .blur(radius: Self.blurRadius)
        default:      return nil
        }
    }
}
