import Cocoa

/// 箭头工具。
///
/// 比别的工具多一步：构造完要把它两端的**对象附着**接上。
/// 吸附判定需要访问画布上已有的对象，所以通过 `ToolContext` 的两个闭包注入，
/// 而不是让 handler 持有画布引用。
struct ArrowToolHandler: AnnotationToolHandler {

    func handles(_ tool: DrawingTool) -> Bool {
        tool == .arrow
    }

    func makeObject(from start: CGPoint, to end: CGPoint,
                    tool: DrawingTool, context: ToolContext) -> (any AnnotationObject)? {
        let arrow = Arrow(startPoint: start, endPoint: end,
                          color: context.color, lineWidth: context.lineWidth,
                          hitTestColorKey: context.colorKey, style: context.arrowStyle)

        arrow.startAttachment = context.detectAttachment(start)
        arrow.endAttachment = context.detectAttachment(end)
        if let attachment = arrow.startAttachment,
           let position = context.resolveAttachmentPosition(attachment) {
            arrow.startPoint = position
        }
        if let attachment = arrow.endAttachment,
           let position = context.resolveAttachmentPosition(attachment) {
            arrow.endPoint = position
        }
        return arrow
    }

    func drawPreview(from start: CGPoint, to end: CGPoint,
                     tool: DrawingTool, in ctx: CGContext, context: ToolContext) {
        let preview = Arrow(startPoint: start, endPoint: end,
                            color: context.color, lineWidth: context.lineWidth,
                            hitTestColorKey: 0, style: context.arrowStyle)
        preview.draw(in: ctx)
    }
}
