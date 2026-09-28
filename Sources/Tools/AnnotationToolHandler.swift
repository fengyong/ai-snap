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
    /// 底图（打码工具要读它的像素）。其余工具用不到，但由画布统一注入，
    /// 于是 handler 不必持有画布引用 —— 这正是拆分的意义。
    let sourceImage: CGImage?
    /// 「画布点 → 底图像素」的倍率。打码的块大小 / 模糊半径都要乘上它。
    let pixelScale: CGFloat

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

    /// 自由手绘类工具（画笔 / 马克笔）：拖拽**逐点采样**、整个点集才是一个对象，
    /// 与「起点→终点」的拖拽构造路径不同。画布据此选择累积点集还是记录终点。
    var isFreehand: Bool { get }

    /// 用整条采样点集构造对象（仅 isFreehand 工具返回非 nil）。
    ///
    /// **必须列进协议本体**（下面 extension 只放默认实现）：Swift 的协议扩展方法
    /// 不参与存在体动态分发 —— 只写在 extension 里的方法，经 `any AnnotationToolHandler`
    /// 调用永远命中默认实现、不会调到具体 handler 的版本（实测踩到：一笔画完
    /// 对象永远是 nil）。与 makeObject/placeObject 是同一个待遇。
    func makeFreehandObject(points: [CGPoint], tool: DrawingTool,
                            context: ToolContext) -> (any AnnotationObject)?

    /// 手绘进行中的预览：把已采到的点集画出来（所见即所得）。
    func drawFreehandPreview(_ points: [CGPoint], tool: DrawingTool,
                             in ctx: CGContext, context: ToolContext)
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

    var isFreehand: Bool { false }

    func makeFreehandObject(points: [CGPoint], tool: DrawingTool,
                            context: ToolContext) -> (any AnnotationObject)? {
        nil
    }

    func drawFreehandPreview(_ points: [CGPoint], tool: DrawingTool,
                             in ctx: CGContext, context: ToolContext) {}
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
        RedactionToolHandler(),
        PenToolHandler(),
    ]

    static func handler(for tool: DrawingTool) -> AnnotationToolHandler? {
        all.first { $0.handles(tool) }
    }
}
