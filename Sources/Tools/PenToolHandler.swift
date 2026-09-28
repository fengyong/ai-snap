import Cocoa

/// 自由画笔与马克笔：拖拽逐点采样，整条笔画是一个 `FreehandShape`。
///
/// 两者共用一个 handler 与一个形状类（isMarker 区分），取舍与「矩形/圆角矩形
/// 共用 RectangleShape」一致：选中、移动、旋转、缩放、撤销、双图层命中全部免费。
///
/// 与拖拽类工具的路径差异：一般拖拽工具只在 mouseUp 拿「起点→终点」两点；
/// 手绘需要**每个 mouseDragged 事件的点**，所以走协议的 `isFreehand` /
/// `makeFreehandObject` / `drawFreehandPreview` 通路（画布负责采样与抽稀，
/// handler 只负责构造与预览 —— 职责分界与拖拽类一致）。
struct PenToolHandler: AnnotationToolHandler {

    func handles(_ tool: DrawingTool) -> Bool {
        tool == .pen || tool == .marker
    }

    var isFreehand: Bool { true }

    func makeFreehandObject(points: [CGPoint], tool: DrawingTool,
                            context: ToolContext) -> (any AnnotationObject)? {
        // 一划只有 1 个点（单击没拖）也接受 —— FreehandShape 会画成圆点，
        // 与「落笔即有痕」的直觉一致
        FreehandShape(points: points,
                      color: context.color,
                      lineWidth: context.lineWidth,
                      isMarker: tool == .marker,
                      hitTestColorKey: context.colorKey)
    }

    func drawFreehandPreview(_ points: [CGPoint], tool: DrawingTool,
                             in ctx: CGContext, context: ToolContext) {
        // 预览 = 同一套渲染路径（所见即所得）；hit key 用 0（预览不进命中层）
        let preview = FreehandShape(points: points,
                                    color: context.color,
                                    lineWidth: context.lineWidth,
                                    isMarker: tool == .marker,
                                    hitTestColorKey: 0)
        preview.draw(in: ctx)
    }
}
