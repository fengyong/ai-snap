import Cocoa

/// 构造标注对象所需的全部输入。
///
/// 把这个结构从 `AnnotationView` 里抽出来，是为了让各工具的构造逻辑**不再依赖画布实例** ——
/// 否则 handler 拿不到颜色、线宽、吸附回调，就只能退回成画布上的一个 switch 分支，
/// 拆分也就白做了。
struct ToolContext {
    let color: NSColor
    let lineWidth: CGFloat
    let lineStyle: LineStyle
    let arrowStyle: ArrowStyle
    /// 是否以起点为中心绘制（起始点吸附到某个 snap point 时为 true）
    let drawingFromCenter: Bool
    /// 聚光灯预览需要知道画布尺寸
    let canvasSize: CGSize
    /// 新建对象的命中色 key
    let colorKey: UInt32

    /// 端点吸附到已有对象（仅箭头用）。需要访问画布对象表，因此由画布注入。
    let detectAttachment: (CGPoint) -> Attachment?
    let resolveAttachmentPosition: (Attachment) -> CGPoint?
    /// 序号标注的下一个编号（画布知道已有哪些序号）
    let nextStepNumber: () -> Int
}

/// 一个绘图工具「如何构造对象」与「如何画拖拽预览」。
///
/// 抽出来的动机很直接：`AnnotationView` 已经 1200+ 行，而每加一个工具就要改三处
/// （mouseDown 的单击分支、mouseUp 的构造 switch、drawPreview 的预览 switch）。
/// 现在加工具只需要新增一个 handler 并在 `ToolRegistry` 里登记。
///
/// 三个方法都有默认实现：拖拽类工具不实现 `placeObject`，单击类不实现
/// `makeObject` / `drawPreview`，互不干扰。
protocol AnnotationToolHandler {
    /// 该 handler 负责哪些工具。一个 handler 可以覆盖多个（如矩形与圆角矩形共用一个）。
    func handles(_ tool: DrawingTool) -> Bool

    /// 拖拽结束时构造对象。返回 nil 表示该工具不由拖拽构造。
    func makeObject(from start: CGPoint, to end: CGPoint,
                    tool: DrawingTool, context: ToolContext) -> (any AnnotationObject)?

    /// 拖拽过程中的预览。
    func drawPreview(from start: CGPoint, to end: CGPoint,
                     tool: DrawingTool, in ctx: CGContext, context: ToolContext)

    /// 单击放置（序号、贴纸）。返回 nil 表示该工具不是单击放置类。
    func placeObject(at point: CGPoint, tool: DrawingTool,
                     context: ToolContext) -> (any AnnotationObject)?
}

extension AnnotationToolHandler {
    func makeObject(from start: CGPoint, to end: CGPoint,
                    tool: DrawingTool, context: ToolContext) -> (any AnnotationObject)? {
        nil
    }

    func drawPreview(from start: CGPoint, to end: CGPoint,
                     tool: DrawingTool, in ctx: CGContext, context: ToolContext) {}

    func placeObject(at point: CGPoint, tool: DrawingTool,
                     context: ToolContext) -> (any AnnotationObject)? {
        nil
    }
}

/// 工具 → handler 的登记表。
///
/// 用「第一个 `handles` 命中的」而不是字典：`DrawingTool` 带关联值
/// （`.stamp(.heart)`）且不是 `Hashable`，而按前缀匹配天然支持「一个 handler
/// 覆盖一组工具」（矩形/圆角矩形，圆/椭圆）这种分组。
enum ToolRegistry {
    private static let all: [AnnotationToolHandler] = [
        ArrowToolHandler(),
        RectangleToolHandler(),
        EllipseToolHandler(),
        SpotlightToolHandler(),
        ClickPlacementToolHandler(),
        TextToolHandler(),
    ]

    static func handler(for tool: DrawingTool) -> AnnotationToolHandler? {
        all.first { $0.handles(tool) }
    }
}
