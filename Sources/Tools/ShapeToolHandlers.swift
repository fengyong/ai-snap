import Cocoa

/// 矩形与圆角矩形。
///
/// 两者共用本 handler：它们是同一个形状类，只差 `cornerRadius`。
/// 圆角半径由 `cornerRadius(for:context:)` 决定（随线宽缩放，见那里的说明）。
struct RectangleToolHandler: AnnotationToolHandler {

    func handles(_ tool: DrawingTool) -> Bool {
        tool == .rectangle || tool == .roundedRectangle
    }

    func makeObject(from start: CGPoint, to end: CGPoint,
                    tool: DrawingTool, context: ToolContext) -> (any AnnotationObject)? {
        let shape: RectangleShape
        if context.drawingFromCenter {
            // 以 start 为中心，拖拽确定半尺寸
            let halfWidth = abs(end.x - start.x)
            let halfHeight = abs(end.y - start.y)
            shape = RectangleShape(center: start,
                                   width: max(halfWidth * 2, 6),
                                   height: max(halfHeight * 2, 6),
                                   color: context.color,
                                   lineWidth: context.lineWidth,
                                   hitTestColorKey: context.colorKey)
        } else {
            shape = RectangleShape(from: start, to: end,
                                   color: context.color,
                                   lineWidth: context.lineWidth,
                                   hitTestColorKey: context.colorKey)
        }
        shape.cornerRadius = Self.cornerRadius(for: tool, context: context)
        shape.lineStyle = context.lineStyle
        return shape
    }

    func drawPreview(from start: CGPoint, to end: CGPoint,
                     tool: DrawingTool, in ctx: CGContext, context: ToolContext) {
        // 预览的下限比正式对象更小（正式是 6，预览是 2）—— 刚起手时也要看得见
        let preview: RectangleShape
        if context.drawingFromCenter {
            preview = RectangleShape(center: start,
                                     width: max(abs(end.x - start.x) * 2, 2),
                                     height: max(abs(end.y - start.y) * 2, 2),
                                     color: context.color,
                                     lineWidth: context.lineWidth,
                                     hitTestColorKey: 0)
        } else {
            preview = RectangleShape(from: start, to: end,
                                     color: context.color,
                                     lineWidth: context.lineWidth,
                                     hitTestColorKey: 0)
        }
        preview.cornerRadius = Self.cornerRadius(for: tool, context: context)
        preview.lineStyle = context.lineStyle
        preview.draw(in: ctx)
    }

    /// 新建圆角矩形时的默认圆角半径 = max(12, 2.5 × 线宽)。
    ///
    /// **为什么必须随线宽缩放**：描边以路径为中心、向两侧各扩 `lineWidth / 2`。
    /// 半径太小时，圆角整块被线宽本身填满，看上去仍是直角 —— 用户点了「圆角」
    /// 却发现没变化。这与之前「虚线 dash 用固定值导致画出来是实线」是同一类问题：
    /// **参数不随线宽缩放，差别就看不见**（参见 LineStyle.apply 的说明）。
    ///
    /// 离屏二分实测「角点从被描边覆盖变为被切掉」的翻转半径：
    ///
    ///   线宽  2 → 5.8    线宽  8 → 13.1    线宽 30 → 39.6
    ///   线宽  4 → 8.2    线宽 15 → 21.5
    ///
    /// 翻转点与线宽的比值随线宽增大而收敛（2.91 → 1.32），细线处更大，由 12 的下限兜住。
    /// 取 2.5 倍是为了在所有线宽下都留出余量，而不是刚好压在翻转点上。
    private static func cornerRadius(for tool: DrawingTool, context: ToolContext) -> CGFloat {
        tool == .roundedRectangle ? max(12, context.lineWidth * 2.5) : 0
    }
}

/// 圆与椭圆。
///
/// 共用一个 handler，因为它们也是同一个形状类（`CircleShape`）：
/// 正圆是 `radiusX == radiusY` 的椭圆。
struct EllipseToolHandler: AnnotationToolHandler {

    func handles(_ tool: DrawingTool) -> Bool {
        tool == .circle || tool == .ellipse
    }

    func makeObject(from start: CGPoint, to end: CGPoint,
                    tool: DrawingTool, context: ToolContext) -> (any AnnotationObject)? {
        makeShape(from: start, to: end, tool: tool, context: context, minimumRadius: 3)
    }

    func drawPreview(from start: CGPoint, to end: CGPoint,
                     tool: DrawingTool, in ctx: CGContext, context: ToolContext) {
        // 预览的下限更小（1 vs 3），刚起手时也看得见
        guard let preview = makeShape(from: start, to: end, tool: tool,
                                      context: context, minimumRadius: 1) else { return }
        preview.draw(in: ctx)
    }

    private func makeShape(from start: CGPoint, to end: CGPoint, tool: DrawingTool,
                           context: ToolContext,
                           minimumRadius: CGFloat) -> CircleShape? {
        let shape: CircleShape
        if context.drawingFromCenter {
            if tool == .circle {
                let radius = hypot(end.x - start.x, end.y - start.y)
                shape = CircleShape(center: start,
                                    radiusX: max(radius, minimumRadius),
                                    radiusY: max(radius, minimumRadius),
                                    color: context.color,
                                    lineWidth: context.lineWidth,
                                    hitTestColorKey: context.colorKey)
            } else {
                shape = CircleShape(center: start,
                                    radiusX: max(abs(end.x - start.x), minimumRadius),
                                    radiusY: max(abs(end.y - start.y), minimumRadius),
                                    color: context.color,
                                    lineWidth: context.lineWidth,
                                    hitTestColorKey: context.colorKey)
            }
        } else {
            let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            if tool == .circle {
                // 正圆取宽高较大者作直径
                let radius = max(abs(end.x - start.x), abs(end.y - start.y)) / 2
                shape = CircleShape(center: center,
                                    radiusX: max(radius, minimumRadius),
                                    radiusY: max(radius, minimumRadius),
                                    color: context.color,
                                    lineWidth: context.lineWidth,
                                    hitTestColorKey: context.colorKey)
            } else {
                shape = CircleShape(center: center,
                                    radiusX: max(abs(end.x - start.x) / 2, minimumRadius),
                                    radiusY: max(abs(end.y - start.y) / 2, minimumRadius),
                                    color: context.color,
                                    lineWidth: context.lineWidth,
                                    hitTestColorKey: context.colorKey)
            }
        }
        shape.lineStyle = context.lineStyle
        return shape
    }
}

/// 聚光灯：框选区域高亮，其余变暗。
///
/// 它是唯一一个「不描边、只影响整幅画面明暗」的工具，所以既不需要颜色也不需要线宽，
/// 预览也直接在画布上下文上叠一层蒙版而不是先造对象再 draw。
struct SpotlightToolHandler: AnnotationToolHandler {

    func handles(_ tool: DrawingTool) -> Bool {
        tool == .spotlight
    }

    func makeObject(from start: CGPoint, to end: CGPoint,
                    tool: DrawingTool, context: ToolContext) -> (any AnnotationObject)? {
        SpotlightShape(from: start, to: end, hitTestColorKey: context.colorKey)
    }

    func drawPreview(from start: CGPoint, to end: CGPoint,
                     tool: DrawingTool, in ctx: CGContext, context: ToolContext) {
        let canvasRect = CGRect(origin: .zero, size: context.canvasSize)
        let spotRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
        let spotPath = CGPath(roundedRect: spotRect, cornerWidth: 8, cornerHeight: 8,
                              transform: nil)

        // 周围变暗：用 evenOdd 规则把「整幅画布 − 选区」作为填充区域
        ctx.saveGState()
        let maskPath = CGMutablePath()
        maskPath.addRect(canvasRect)
        maskPath.addPath(spotPath)
        ctx.addPath(maskPath)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(canvasRect)
        ctx.restoreGState()

        // 中心提亮
        ctx.saveGState()
        ctx.addPath(spotPath)
        ctx.clip()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.fill(canvasRect)
        ctx.restoreGState()

        // 选区边框
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 3])
        ctx.addPath(spotPath)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }
}
