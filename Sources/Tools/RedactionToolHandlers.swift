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
        guard let shape = makeShape(from: start, to: end,
                                    style: style(for: tool),
                                    drawingFromCenter: context.drawingFromCenter,
                                    colorKey: context.colorKey) else { return nil }
        shape.sourceImage = context.sourceImage
        shape.pixelScale = context.pixelScale
        return shape
    }

    func drawPreview(from start: CGPoint, to end: CGPoint,
                     tool: DrawingTool, in ctx: CGContext, context: ToolContext) {
        // 预览**必须**由与最终对象同一个构造出来，否则两者会漂移。
        //
        // 原来预览无条件用 `RedactionShape(from:to:)`，完全忽略了 `drawingFromCenter`
        // （起点吸附到某个角点时，最终对象是「以起点为中心、尺寸翻倍」的）。
        // 于是用户看到的是一小块预览，松手却打码了另一块**大一倍**的区域 ——
        // 对打码这种隐私保护手段来说，这是实打实的错误结果。
        //
        // 兄弟 handler（矩形、椭圆）都让两条路径共用一个构造（见
        // `EllipseToolHandler.makeShape`），打码当时漏了。
        guard let preview = makeShape(from: start, to: end,
                                      style: style(for: tool),
                                      drawingFromCenter: context.drawingFromCenter,
                                      colorKey: 0) else { return }
        preview.sourceImage = context.sourceImage
        preview.pixelScale = context.pixelScale
        // 预览就按最终效果画（同一套渲染路径），所见即所得。
        // 代价是每帧重算一次打码 —— 但这正是缓存键里带矩形尺寸的原因：
        // 尺寸不变时（拖拽停止后）直接命中缓存，不会反复算。
        preview.draw(in: ctx)
    }

    /// 预览与最终对象**共用这一个构造**。
    ///
    /// `drawingFromCenter` 只有一个处理点 —— 两条路径都从这里过，
    /// 于是「预览」与「落框」在结构上就不可能不一致。
    private func makeShape(from start: CGPoint, to end: CGPoint,
                           style: RedactionStyle?,
                           drawingFromCenter: Bool,
                           colorKey: UInt32) -> RedactionShape? {
        guard let style = style else { return nil }
        if drawingFromCenter {
            // 以 start 为中心，拖拽确定半尺寸（与矩形/椭圆的语义一致）
            return RedactionShape(center: start,
                                  width: max(abs(end.x - start.x) * 2, 6),
                                  height: max(abs(end.y - start.y) * 2, 6),
                                  style: style,
                                  hitTestColorKey: colorKey)
        }
        return RedactionShape(from: start, to: end,
                              style: style,
                              hitTestColorKey: colorKey)
    }

    /// 打码强度**基准值**。12 点的块/半径已经足以让屏幕上的正文和数字无法辨认。
    /// 实际值 = 基准 × 偏好系数（`Preferences.redactionStrength`，0.5…3.0，
    /// 设置窗口可调）—— 小图（表情包）可以调细，4K 大屏截图可以调粗。
    static let mosaicBlockSize: CGFloat = 12
    static let blurRadius: CGFloat = 12

    private func style(for tool: DrawingTool) -> RedactionStyle? {
        let strength = CGFloat(Preferences.shared.redactionStrength)
        switch tool {
        case .mosaic: return .mosaic(blockSize: Self.mosaicBlockSize * strength)
        case .blur:   return .blur(radius: Self.blurRadius * strength)
        default:      return nil
        }
    }
}
