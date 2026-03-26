import Cocoa

struct Arrow {
    let id: UUID
    var startPoint: CGPoint
    var endPoint: CGPoint
    var color: NSColor
    var lineWidth: CGFloat
    let hitTestColorKey: UInt32  // 隐藏图层中的唯一颜色

    init(startPoint: CGPoint, endPoint: CGPoint, color: NSColor,
         lineWidth: CGFloat = 3.0, hitTestColorKey: UInt32) {
        self.id = UUID()
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.lineWidth = lineWidth
        self.hitTestColorKey = hitTestColorKey
    }

    /// 在指定 CGContext 上绘制箭头
    func draw(in ctx: CGContext, withColor overrideColor: NSColor? = nil,
              lineWidthOverride: CGFloat? = nil) {
        let drawColor = overrideColor ?? color
        let lw = lineWidthOverride ?? lineWidth

        ctx.setStrokeColor(drawColor.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 箭身
        ctx.move(to: startPoint)
        ctx.addLine(to: endPoint)
        ctx.strokePath()

        // 箭头 (三角形)
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let arrowLength: CGFloat = 14
        let arrowAngle: CGFloat = .pi / 6

        let p1 = CGPoint(
            x: endPoint.x - arrowLength * cos(angle - arrowAngle),
            y: endPoint.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: endPoint.x - arrowLength * cos(angle + arrowAngle),
            y: endPoint.y - arrowLength * sin(angle + arrowAngle)
        )

        ctx.setFillColor(drawColor.cgColor)
        ctx.move(to: endPoint)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
    }
}

enum CanvasState {
    case idle
    case drawing(start: CGPoint)
    case moving(colorKey: UInt32, grabOffset: CGVector)
}
