import Cocoa

/// 放大镜：单击放置一个圆形放大区域，内容取自底图、随拖动实时重取样。
///
/// 单击放置类（与序号/贴纸同路径）：`placeObject` 返回对象即完成放置，
/// 画布零改动。放置后移动 = 换取样位置（缓存键含圆心），缩放 = 改半径，
/// 放大倍数固定 2.5×（一个旋钮一个含义；要可调再进偏好）。
struct MagnifierToolHandler: AnnotationToolHandler {

    func handles(_ tool: DrawingTool) -> Bool {
        tool == .magnifier
    }

    func placeObject(at point: CGPoint, tool: DrawingTool,
                     context: ToolContext) -> (any AnnotationObject)? {
        let shape = MagnifierShape(
            center: point,
            radius: MagnifierShape.defaultRadius,
            zoom: MagnifierShape.defaultZoom,
            color: context.color,
            // 环宽用当前线宽但设下限：线宽调到 2 时环细得看不见，放大镜会像一块透明圆
            lineWidth: max(context.lineWidth, 3),
            hitTestColorKey: context.colorKey)
        // 与打码同一约定：源图与倍率由 handler 注入（画布不进 handler 的依赖图）
        shape.sourceImage = context.sourceImage
        shape.pixelScale = context.pixelScale
        return shape
    }
}
