import Cocoa

// MARK: - Geometry Helpers

func rotatePoint(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
    let dx = point.x - center.x
    let dy = point.y - center.y
    let cosA = cos(angle)
    let sinA = sin(angle)
    return CGPoint(
        x: center.x + dx * cosA - dy * sinA,
        y: center.y + dx * sinA + dy * cosA
    )
}

func scalePoint(_ point: CGPoint, from center: CGPoint, by factor: CGFloat) -> CGPoint {
    return CGPoint(
        x: center.x + (point.x - center.x) * factor,
        y: center.y + (point.y - center.y) * factor
    )
}

func distanceBetween(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    return hypot(a.x - b.x, a.y - b.y)
}

// MARK: - Snap Points

enum SnapPointType {
    case center
    case corner
    case midpoint
    case endpoint
    case quadrant
}

struct SnapPoint {
    let point: CGPoint
    let type: SnapPointType
}

// MARK: - Attachment

enum AnchorType {
    case snapPoint(index: Int)
    case perimeter(parameter: CGFloat) // 0...1
}

struct Attachment {
    let parentKey: UInt32
    var anchorType: AnchorType
}

// MARK: - Arrow Style

enum ArrowHeadType {
    case triangle
    case open
    case diamond
    case none
}

enum ArrowTailType {
    case none
    case circle
    case perpendicular
}

enum LineStyle {
    case solid
    case dashed
    case dotted
}

struct ArrowStyle {
    var headType: ArrowHeadType
    var tailType: ArrowTailType
    var lineStyle: LineStyle
    var headLength: CGFloat
    var headAngle: CGFloat

    static let `default` = ArrowStyle(
        headType: .triangle, tailType: .none, lineStyle: .solid,
        headLength: 14, headAngle: .pi / 6
    )

    static let openArrow = ArrowStyle(
        headType: .open, tailType: .none, lineStyle: .solid,
        headLength: 14, headAngle: .pi / 6
    )

    static let dashedArrow = ArrowStyle(
        headType: .triangle, tailType: .none, lineStyle: .dashed,
        headLength: 14, headAngle: .pi / 6
    )

    static let diamondArrow = ArrowStyle(
        headType: .diamond, tailType: .none, lineStyle: .solid,
        headLength: 14, headAngle: .pi / 6
    )

    static let circleEndpoints = ArrowStyle(
        headType: .none, tailType: .circle, lineStyle: .solid,
        headLength: 14, headAngle: .pi / 6
    )

    static let dottedDiamond = ArrowStyle(
        headType: .diamond, tailType: .none, lineStyle: .dotted,
        headLength: 14, headAngle: .pi / 6
    )

    static let allPresets: [ArrowStyle] = [
        .default, .openArrow, .dashedArrow, .diamondArrow, .circleEndpoints, .dottedDiamond
    ]

    static let presetNames: [String] = [
        "实心", "开放", "虚线", "菱形", "圆端", "点菱"
    ]
}

// MARK: - Color Palette

struct ColorPalette {
    let name: String
    let colors: [NSColor]

    static let vivid = ColorPalette(name: "鲜明", colors: [
        .systemRed, .systemBlue, .systemGreen, .systemYellow
    ])

    static let professional = ColorPalette(name: "专业", colors: [
        NSColor(red: 0.176, green: 0.204, blue: 0.212, alpha: 1),  // #2D3436
        NSColor(red: 0.035, green: 0.518, blue: 0.890, alpha: 1),  // #0984E3
        NSColor(red: 0.000, green: 0.722, blue: 0.580, alpha: 1),  // #00B894
        NSColor(red: 0.882, green: 0.439, blue: 0.333, alpha: 1),  // #E17055
        NSColor(red: 0.416, green: 0.220, blue: 0.678, alpha: 1),  // #6A38AD
    ])

    static let pastel = ColorPalette(name: "柔和", colors: [
        NSColor(red: 0.980, green: 0.694, blue: 0.627, alpha: 1),  // #FAB1A0
        NSColor(red: 0.506, green: 0.925, blue: 0.925, alpha: 1),  // #81ECEC
        NSColor(red: 0.635, green: 0.608, blue: 0.996, alpha: 1),  // #A29BFE
        NSColor(red: 1.000, green: 0.918, blue: 0.655, alpha: 1),  // #FFEAA7
        NSColor(red: 0.333, green: 0.937, blue: 0.769, alpha: 1),  // #55EFC4
    ])

    static let highContrast = ColorPalette(name: "高对比", colors: [
        .white,
        NSColor(red: 1, green: 0, blue: 0, alpha: 1),
        NSColor(red: 0, green: 1, blue: 0, alpha: 1),
        NSColor(red: 1, green: 1, blue: 0, alpha: 1),
    ])

    static let monochrome = ColorPalette(name: "灰度", colors: [
        .black,
        NSColor(white: 0.333, alpha: 1),
        NSColor(white: 0.667, alpha: 1),
        .white,
    ])

    static let allPalettes: [ColorPalette] = [
        .vivid, .professional, .pastel, .highContrast, .monochrome
    ]
}

// MARK: - Watermark Config

struct WatermarkConfig {
    var text: String = "AISnap"
    var enabled: Bool = false
    var fontSize: CGFloat = 14
    var color: NSColor = NSColor.white.withAlphaComponent(0.3)
    var tiled: Bool = true       // true = 平铺; false = 右下角单个
    var tileSpacing: CGFloat = 120
    var angle: CGFloat = -.pi / 6  // 平铺旋转角度（-30度）
}

// MARK: - Stamp Type

enum StampType {
    case emoji(String)
    case checkmark
    case crossmark
    case exclamation
}

/// 预设表情/符号列表
let defaultStamps: [(StampType, String)] = [
    (.checkmark, "\u{2713}"), (.crossmark, "\u{2717}"), (.exclamation, "!"),
    (.emoji("\u{1F44D}"), "\u{1F44D}"), (.emoji("\u{1F44E}"), "\u{1F44E}"), (.emoji("\u{2764}\u{FE0F}"), "\u{2764}\u{FE0F}"),
    (.emoji("\u{2B50}"), "\u{2B50}"), (.emoji("\u{1F525}"), "\u{1F525}"), (.emoji("\u{1F4A1}"), "\u{1F4A1}"),
    (.emoji("\u{2753}"), "\u{2753}"), (.emoji("\u{26A0}\u{FE0F}"), "\u{26A0}\u{FE0F}"), (.emoji("\u{1F3AF}"), "\u{1F3AF}"),
    (.emoji("\u{1F4CC}"), "\u{1F4CC}"), (.emoji("\u{1F4AC}"), "\u{1F4AC}"), (.emoji("\u{1F50D}"), "\u{1F50D}"),
    (.emoji("\u{1F446}"), "\u{1F446}"), (.emoji("\u{2705}"), "\u{2705}"), (.emoji("\u{1F389}"), "\u{1F389}"),
]

// MARK: - Undo Action

enum UndoAction {
    /// 添加了一个对象（撤销 = 删除它）
    case add(colorKey: UInt32)
    /// 删除了对象（撤销 = 重新添加，包含被级联删除的子箭头）
    case delete(objects: [(UInt32, any AnnotationObject)], zOrderSnapshot: [UInt32])
    /// 移动了对象（撤销 = 反向移动）
    case move(colorKey: UInt32, delta: CGVector)
    /// 旋转了对象
    case rotate(colorKey: UInt32, angle: CGFloat)
    /// 缩放了对象
    case scale(colorKey: UInt32, factor: CGFloat)
}

// MARK: - Drawing Tool & Canvas State

enum DrawingTool: Equatable {
    case arrow
    case rectangle
    case circle
    case stamp(StampType)
    case spotlight

    static func == (lhs: DrawingTool, rhs: DrawingTool) -> Bool {
        switch (lhs, rhs) {
        case (.arrow, .arrow), (.rectangle, .rectangle),
             (.circle, .circle), (.spotlight, .spotlight):
            return true
        case (.stamp, .stamp):
            return true  // 所有 stamp 视为同类工具
        default:
            return false
        }
    }
}

enum CanvasState {
    case idle
    case drawing(tool: DrawingTool, start: CGPoint)
    case moving(colorKey: UInt32, grabOffset: CGVector)
    case rotating(colorKey: UInt32, lastAngle: CGFloat)
    case scaling(colorKey: UInt32, lastDistance: CGFloat)
}

// MARK: - AnnotationObject Protocol

/// All annotation objects conform to this protocol.
/// Uses AnyObject (class-only) so objects can be mutated in-place in the dictionary.
protocol AnnotationObject: AnyObject {
    var id: UUID { get }
    var hitTestColorKey: UInt32 { get }

    /// Object center in canvas coordinates
    var center: CGPoint { get }
    /// Rotation angle in radians
    var rotation: CGFloat { get }
    /// Primary color
    var color: NSColor { get set }

    /// Axis-aligned bounding box
    var boundingBox: CGRect { get }

    /// Draw on Layer A (user-visible)
    func draw(in ctx: CGContext)
    /// Draw on Layer B (hit test, unique color, no anti-aliasing)
    func drawHitTest(in ctx: CGContext, color: NSColor)

    /// Points for selection handles
    func selectionHandlePoints() -> [CGPoint]

    /// Snap points this object exposes
    func snapPoints() -> [SnapPoint]
    /// Nearest point on perimeter to a given point
    func nearestPerimeterPoint(to point: CGPoint) -> CGPoint

    /// Transform operations
    func move(by delta: CGVector)
    func rotate(by angle: CGFloat)
    func scale(by factor: CGFloat)
}

// MARK: - Arrow

class Arrow: AnnotationObject {
    let id: UUID
    let hitTestColorKey: UInt32
    var startPoint: CGPoint
    var endPoint: CGPoint
    var color: NSColor
    var lineWidth: CGFloat
    var style: ArrowStyle
    var startAttachment: Attachment?
    var endAttachment: Attachment?

    init(startPoint: CGPoint, endPoint: CGPoint, color: NSColor,
         lineWidth: CGFloat = 3.0, hitTestColorKey: UInt32,
         style: ArrowStyle = .default) {
        self.id = UUID()
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.lineWidth = lineWidth
        self.hitTestColorKey = hitTestColorKey
        self.style = style
    }

    var center: CGPoint {
        CGPoint(x: (startPoint.x + endPoint.x) / 2,
                y: (startPoint.y + endPoint.y) / 2)
    }

    var rotation: CGFloat {
        atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
    }

    var boundingBox: CGRect {
        let padding = lineWidth + style.headLength
        let minX = min(startPoint.x, endPoint.x) - padding
        let minY = min(startPoint.y, endPoint.y) - padding
        let maxX = max(startPoint.x, endPoint.x) + padding
        let maxY = max(startPoint.y, endPoint.y) + padding
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Drawing

    func draw(in ctx: CGContext) {
        drawArrow(in: ctx, withColor: color, lw: lineWidth)
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        drawArrow(in: ctx, withColor: color, lw: lineWidth + 6)
    }

    private func drawArrow(in ctx: CGContext, withColor drawColor: NSColor, lw: CGFloat) {
        ctx.setStrokeColor(drawColor.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Line style
        switch style.lineStyle {
        case .solid:
            ctx.setLineDash(phase: 0, lengths: [])
        case .dashed:
            ctx.setLineDash(phase: 0, lengths: [8, 4])
        case .dotted:
            ctx.setLineDash(phase: 0, lengths: [2, 4])
        }

        // Shaft
        ctx.move(to: startPoint)
        ctx.addLine(to: endPoint)
        ctx.strokePath()

        // Reset dash for head/tail
        ctx.setLineDash(phase: 0, lengths: [])

        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)

        // Head
        switch style.headType {
        case .triangle:
            let p1 = CGPoint(
                x: endPoint.x - style.headLength * cos(angle - style.headAngle),
                y: endPoint.y - style.headLength * sin(angle - style.headAngle))
            let p2 = CGPoint(
                x: endPoint.x - style.headLength * cos(angle + style.headAngle),
                y: endPoint.y - style.headLength * sin(angle + style.headAngle))
            ctx.setFillColor(drawColor.cgColor)
            ctx.move(to: endPoint)
            ctx.addLine(to: p1)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.fillPath()

        case .open:
            let p1 = CGPoint(
                x: endPoint.x - style.headLength * cos(angle - style.headAngle),
                y: endPoint.y - style.headLength * sin(angle - style.headAngle))
            let p2 = CGPoint(
                x: endPoint.x - style.headLength * cos(angle + style.headAngle),
                y: endPoint.y - style.headLength * sin(angle + style.headAngle))
            ctx.move(to: p1)
            ctx.addLine(to: endPoint)
            ctx.addLine(to: p2)
            ctx.strokePath()

        case .diamond:
            let mid = CGPoint(
                x: endPoint.x - style.headLength * 0.5 * cos(angle),
                y: endPoint.y - style.headLength * 0.5 * sin(angle))
            let p1 = CGPoint(
                x: mid.x - style.headLength * 0.4 * cos(angle - .pi / 2),
                y: mid.y - style.headLength * 0.4 * sin(angle - .pi / 2))
            let p2 = CGPoint(
                x: mid.x + style.headLength * 0.4 * cos(angle - .pi / 2),
                y: mid.y + style.headLength * 0.4 * sin(angle - .pi / 2))
            let back = CGPoint(
                x: endPoint.x - style.headLength * cos(angle),
                y: endPoint.y - style.headLength * sin(angle))
            ctx.setFillColor(drawColor.cgColor)
            ctx.move(to: endPoint)
            ctx.addLine(to: p1)
            ctx.addLine(to: back)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.fillPath()

        case .none:
            break
        }

        // Tail
        switch style.tailType {
        case .none:
            break
        case .circle:
            let r: CGFloat = 4
            let rect = CGRect(x: startPoint.x - r, y: startPoint.y - r,
                              width: r * 2, height: r * 2)
            ctx.setFillColor(drawColor.cgColor)
            ctx.fillEllipse(in: rect)
        case .perpendicular:
            let perpAngle = angle + .pi / 2
            let halfLen: CGFloat = 6
            let p1 = CGPoint(x: startPoint.x + halfLen * cos(perpAngle),
                             y: startPoint.y + halfLen * sin(perpAngle))
            let p2 = CGPoint(x: startPoint.x - halfLen * cos(perpAngle),
                             y: startPoint.y - halfLen * sin(perpAngle))
            ctx.move(to: p1)
            ctx.addLine(to: p2)
            ctx.strokePath()
        }
    }

    // MARK: Selection & Snap

    func selectionHandlePoints() -> [CGPoint] {
        [startPoint, endPoint]
    }

    func snapPoints() -> [SnapPoint] {
        [
            SnapPoint(point: startPoint, type: .endpoint),
            SnapPoint(point: endPoint, type: .endpoint),
            SnapPoint(point: center, type: .center),
        ]
    }

    func nearestPerimeterPoint(to point: CGPoint) -> CGPoint {
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return startPoint }
        let t = max(0, min(1, ((point.x - startPoint.x) * dx + (point.y - startPoint.y) * dy) / lenSq))
        return CGPoint(x: startPoint.x + t * dx, y: startPoint.y + t * dy)
    }

    // MARK: Transform

    func move(by delta: CGVector) {
        startPoint.x += delta.dx
        startPoint.y += delta.dy
        endPoint.x += delta.dx
        endPoint.y += delta.dy
    }

    func rotate(by angle: CGFloat) {
        let c = center
        startPoint = rotatePoint(startPoint, around: c, by: angle)
        endPoint = rotatePoint(endPoint, around: c, by: angle)
    }

    func scale(by factor: CGFloat) {
        let c = center
        startPoint = scalePoint(startPoint, from: c, by: factor)
        endPoint = scalePoint(endPoint, from: c, by: factor)
    }
}

// MARK: - RectangleShape

class RectangleShape: AnnotationObject {
    let id: UUID
    let hitTestColorKey: UInt32
    var center: CGPoint
    var width: CGFloat
    var height: CGFloat
    var rotation: CGFloat
    var color: NSColor
    var lineWidth: CGFloat

    init(center: CGPoint, width: CGFloat, height: CGFloat,
         color: NSColor, lineWidth: CGFloat = 2.0, hitTestColorKey: UInt32) {
        self.id = UUID()
        self.center = center
        self.width = width
        self.height = height
        self.rotation = 0
        self.color = color
        self.lineWidth = lineWidth
        self.hitTestColorKey = hitTestColorKey
    }

    /// Create from two-point drag (opposite corners)
    convenience init(from pointA: CGPoint, to pointB: CGPoint,
                     color: NSColor, lineWidth: CGFloat = 2.0, hitTestColorKey: UInt32) {
        let cx = (pointA.x + pointB.x) / 2
        let cy = (pointA.y + pointB.y) / 2
        let w = abs(pointB.x - pointA.x)
        let h = abs(pointB.y - pointA.y)
        self.init(center: CGPoint(x: cx, y: cy), width: w, height: h,
                  color: color, lineWidth: lineWidth, hitTestColorKey: hitTestColorKey)
    }

    var boundingBox: CGRect {
        let corners = cornerPoints()
        let xs = corners.map { $0.x }
        let ys = corners.map { $0.y }
        let padding = lineWidth
        return CGRect(x: xs.min()! - padding, y: ys.min()! - padding,
                      width: (xs.max()! - xs.min()!) + padding * 2,
                      height: (ys.max()! - ys.min()!) + padding * 2)
    }

    /// 4 corner points in canvas coordinates (after rotation)
    func cornerPoints() -> [CGPoint] {
        let hw = width / 2, hh = height / 2
        let locals = [
            CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
            CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh),
        ]
        return locals.map { local in
            rotatePoint(CGPoint(x: center.x + local.x, y: center.y + local.y),
                        around: center, by: rotation)
        }
    }

    /// 4 edge midpoints in canvas coordinates
    func edgeMidpoints() -> [CGPoint] {
        let hw = width / 2, hh = height / 2
        let locals = [
            CGPoint(x: 0, y: -hh), CGPoint(x: hw, y: 0),
            CGPoint(x: 0, y: hh), CGPoint(x: -hw, y: 0),
        ]
        return locals.map { local in
            rotatePoint(CGPoint(x: center.x + local.x, y: center.y + local.y),
                        around: center, by: rotation)
        }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.stroke(rect)
        ctx.restoreGState()
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth + 6)
        ctx.stroke(rect)
        ctx.restoreGState()
    }

    // MARK: Selection & Snap

    func selectionHandlePoints() -> [CGPoint] {
        cornerPoints()
    }

    func snapPoints() -> [SnapPoint] {
        var points = [SnapPoint(point: center, type: .center)]
        for corner in cornerPoints() {
            points.append(SnapPoint(point: corner, type: .corner))
        }
        for mid in edgeMidpoints() {
            points.append(SnapPoint(point: mid, type: .midpoint))
        }
        return points
    }

    func nearestPerimeterPoint(to point: CGPoint) -> CGPoint {
        // Transform to local coordinates
        let localPt = rotatePoint(point, around: center, by: -rotation)
        let lx = localPt.x - center.x
        let ly = localPt.y - center.y
        let hw = width / 2, hh = height / 2
        let cx = max(-hw, min(hw, lx))
        let cy = max(-hh, min(hh, ly))

        var nearest: CGPoint
        if abs(cx) < hw && abs(cy) < hh {
            // Inside: find nearest edge
            let dists = [cx + hw, hw - cx, cy + hh, hh - cy]
            let minD = dists.min()!
            if minD == dists[0] { nearest = CGPoint(x: -hw, y: cy) }
            else if minD == dists[1] { nearest = CGPoint(x: hw, y: cy) }
            else if minD == dists[2] { nearest = CGPoint(x: cx, y: -hh) }
            else { nearest = CGPoint(x: cx, y: hh) }
        } else {
            nearest = CGPoint(x: cx, y: cy)
        }

        return rotatePoint(CGPoint(x: center.x + nearest.x, y: center.y + nearest.y),
                           around: center, by: rotation)
    }

    /// 周长参数 (0...1) → 对应的周长上的世界坐标点
    func pointOnPerimeter(at parameter: CGFloat) -> CGPoint {
        let hw = width / 2, hh = height / 2
        let perimeter = 2 * (width + height)
        let d = parameter * perimeter
        var local: CGPoint
        if d < width {
            local = CGPoint(x: -hw + d, y: -hh)
        } else if d < width + height {
            local = CGPoint(x: hw, y: -hh + (d - width))
        } else if d < 2 * width + height {
            local = CGPoint(x: hw - (d - width - height), y: hh)
        } else {
            local = CGPoint(x: -hw, y: hh - (d - 2 * width - height))
        }
        return rotatePoint(CGPoint(x: center.x + local.x, y: center.y + local.y),
                           around: center, by: rotation)
    }

    // MARK: Transform

    func move(by delta: CGVector) {
        center.x += delta.dx
        center.y += delta.dy
    }

    func rotate(by angle: CGFloat) {
        rotation += angle
    }

    func scale(by factor: CGFloat) {
        width *= abs(factor)
        height *= abs(factor)
    }
}

// MARK: - CircleShape

class CircleShape: AnnotationObject {
    let id: UUID
    let hitTestColorKey: UInt32
    var center: CGPoint
    var radius: CGFloat
    var rotation: CGFloat // matters for snap/attachment alignment
    var color: NSColor
    var lineWidth: CGFloat

    init(center: CGPoint, radius: CGFloat, color: NSColor,
         lineWidth: CGFloat = 2.0, hitTestColorKey: UInt32) {
        self.id = UUID()
        self.center = center
        self.radius = radius
        self.rotation = 0
        self.color = color
        self.lineWidth = lineWidth
        self.hitTestColorKey = hitTestColorKey
    }

    var boundingBox: CGRect {
        let r = radius + lineWidth
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    /// 4 quadrant points (0, 90, 180, 270 degrees, offset by rotation)
    func quadrantPoints() -> [CGPoint] {
        [CGFloat(0), .pi / 2, .pi, 3 * .pi / 2].map { a in
            CGPoint(x: center.x + radius * cos(a + rotation),
                    y: center.y + radius * sin(a + rotation))
        }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: rect)
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth + 6)
        ctx.strokeEllipse(in: rect)
    }

    // MARK: Selection & Snap

    func selectionHandlePoints() -> [CGPoint] {
        quadrantPoints()
    }

    func snapPoints() -> [SnapPoint] {
        var points = [SnapPoint(point: center, type: .center)]
        for qp in quadrantPoints() {
            points.append(SnapPoint(point: qp, type: .quadrant))
        }
        return points
    }

    func nearestPerimeterPoint(to point: CGPoint) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = hypot(dx, dy)
        guard dist > 0 else {
            return CGPoint(x: center.x + radius, y: center.y)
        }
        return CGPoint(x: center.x + radius * dx / dist,
                       y: center.y + radius * dy / dist)
    }

    /// 周长参数 (0...1) → 圆周上的世界坐标点
    func pointOnPerimeter(at parameter: CGFloat) -> CGPoint {
        let angle = parameter * 2 * .pi + rotation
        return CGPoint(x: center.x + radius * cos(angle),
                       y: center.y + radius * sin(angle))
    }

    // MARK: Transform

    func move(by delta: CGVector) {
        center.x += delta.dx
        center.y += delta.dy
    }

    func rotate(by angle: CGFloat) {
        rotation += angle
    }

    func scale(by factor: CGFloat) {
        radius *= abs(factor)
    }
}

// MARK: - StampObject

class StampObject: AnnotationObject {
    let id: UUID
    let hitTestColorKey: UInt32
    var center: CGPoint
    var size: CGFloat
    var rotation: CGFloat
    var color: NSColor // used for vector stamps; emoji ignores this
    var stampType: StampType

    init(center: CGPoint, size: CGFloat = 32, stampType: StampType,
         color: NSColor = .systemRed, hitTestColorKey: UInt32) {
        self.id = UUID()
        self.center = center
        self.size = size
        self.rotation = 0
        self.color = color
        self.stampType = stampType
        self.hitTestColorKey = hitTestColorKey
    }

    var boundingBox: CGRect {
        let half = size / 2 + 2
        return CGRect(x: center.x - half, y: center.y - half,
                      width: half * 2, height: half * 2)
    }

    // MARK: Drawing

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)

        switch stampType {
        case .emoji(let emoji):
            drawEmoji(emoji, in: ctx)
        case .checkmark:
            drawCheckmark(in: ctx)
        case .crossmark:
            drawCrossmark(in: ctx)
        case .exclamation:
            drawExclamation(in: ctx)
        }

        ctx.restoreGState()
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        // All stamps: filled bounding rect for hit test
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let half = size / 2
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: -half, y: -half, width: size, height: size))
        ctx.restoreGState()
    }

    private func drawEmoji(_ emoji: String, in ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: size * 0.8)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let nsStr = emoji as NSString
        let textSize = nsStr.size(withAttributes: attrs)
        let drawPoint = CGPoint(x: -textSize.width / 2, y: -textSize.height / 2)
        nsStr.draw(at: drawPoint, withAttributes: attrs)
    }

    private func drawCheckmark(in ctx: CGContext) {
        let s = size / 2
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(size * 0.12)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: -s * 0.5, y: 0))
        ctx.addLine(to: CGPoint(x: -s * 0.1, y: -s * 0.4))
        ctx.addLine(to: CGPoint(x: s * 0.5, y: s * 0.5))
        ctx.strokePath()
    }

    private func drawCrossmark(in ctx: CGContext) {
        let s = size / 2 * 0.5
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(size * 0.12)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: -s, y: -s))
        ctx.addLine(to: CGPoint(x: s, y: s))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: -s, y: s))
        ctx.addLine(to: CGPoint(x: s, y: -s))
        ctx.strokePath()
    }

    private func drawExclamation(in ctx: CGContext) {
        let s = size / 2
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(size * 0.12)
        ctx.setLineCap(.round)
        // Stem
        ctx.move(to: CGPoint(x: 0, y: s * 0.6))
        ctx.addLine(to: CGPoint(x: 0, y: -s * 0.2))
        ctx.strokePath()
        // Dot
        let dotR = size * 0.07
        ctx.fillEllipse(in: CGRect(x: -dotR, y: -s * 0.5 - dotR,
                                   width: dotR * 2, height: dotR * 2))
    }

    // MARK: Selection & Snap

    func selectionHandlePoints() -> [CGPoint] {
        let half = size / 2
        let locals = [
            CGPoint(x: -half, y: -half), CGPoint(x: half, y: -half),
            CGPoint(x: half, y: half), CGPoint(x: -half, y: half),
        ]
        return locals.map { local in
            rotatePoint(CGPoint(x: center.x + local.x, y: center.y + local.y),
                        around: center, by: rotation)
        }
    }

    func snapPoints() -> [SnapPoint] {
        var points = [SnapPoint(point: center, type: .center)]
        for handle in selectionHandlePoints() {
            points.append(SnapPoint(point: handle, type: .corner))
        }
        return points
    }

    func nearestPerimeterPoint(to point: CGPoint) -> CGPoint {
        let localPt = rotatePoint(point, around: center, by: -rotation)
        let lx = localPt.x - center.x
        let ly = localPt.y - center.y
        let half = size / 2
        let cx = max(-half, min(half, lx))
        let cy = max(-half, min(half, ly))

        var nearest: CGPoint
        if abs(cx) < half && abs(cy) < half {
            let dists = [cx + half, half - cx, cy + half, half - cy]
            let minD = dists.min()!
            if minD == dists[0] { nearest = CGPoint(x: -half, y: cy) }
            else if minD == dists[1] { nearest = CGPoint(x: half, y: cy) }
            else if minD == dists[2] { nearest = CGPoint(x: cx, y: -half) }
            else { nearest = CGPoint(x: cx, y: half) }
        } else {
            nearest = CGPoint(x: cx, y: cy)
        }

        return rotatePoint(CGPoint(x: center.x + nearest.x, y: center.y + nearest.y),
                           around: center, by: rotation)
    }

    /// 周长参数 (0...1) → 正方形包围盒周长上的世界坐标点
    func pointOnPerimeter(at parameter: CGFloat) -> CGPoint {
        let half = size / 2
        let perimeter = size * 4
        let d = parameter * perimeter
        var local: CGPoint
        if d < size {
            local = CGPoint(x: -half + d, y: -half)
        } else if d < 2 * size {
            local = CGPoint(x: half, y: -half + (d - size))
        } else if d < 3 * size {
            local = CGPoint(x: half - (d - 2 * size), y: half)
        } else {
            local = CGPoint(x: -half, y: half - (d - 3 * size))
        }
        return rotatePoint(CGPoint(x: center.x + local.x, y: center.y + local.y),
                           around: center, by: rotation)
    }

    // MARK: Transform

    func move(by delta: CGVector) {
        center.x += delta.dx
        center.y += delta.dy
    }

    func rotate(by angle: CGFloat) {
        rotation += angle
    }

    func scale(by factor: CGFloat) {
        size *= abs(factor)
    }
}

// MARK: - SpotlightShape

class SpotlightShape: AnnotationObject {
    let id: UUID
    let hitTestColorKey: UInt32
    var center: CGPoint
    var width: CGFloat
    var height: CGFloat
    var rotation: CGFloat
    var color: NSColor
    var cornerRadius: CGFloat

    init(center: CGPoint, width: CGFloat, height: CGFloat,
         color: NSColor = NSColor.black.withAlphaComponent(0.5),
         cornerRadius: CGFloat = 8, hitTestColorKey: UInt32) {
        self.id = UUID()
        self.center = center
        self.width = width
        self.height = height
        self.rotation = 0
        self.color = color
        self.cornerRadius = cornerRadius
        self.hitTestColorKey = hitTestColorKey
    }

    convenience init(from pointA: CGPoint, to pointB: CGPoint,
                     color: NSColor = NSColor.black.withAlphaComponent(0.5),
                     cornerRadius: CGFloat = 8, hitTestColorKey: UInt32) {
        let cx = (pointA.x + pointB.x) / 2
        let cy = (pointA.y + pointB.y) / 2
        let w = abs(pointB.x - pointA.x)
        let h = abs(pointB.y - pointA.y)
        self.init(center: CGPoint(x: cx, y: cy), width: w, height: h,
                  color: color, cornerRadius: cornerRadius, hitTestColorKey: hitTestColorKey)
    }

    var boundingBox: CGRect {
        let hw = width / 2, hh = height / 2
        return CGRect(x: center.x - hw, y: center.y - hh, width: width, height: height)
    }

    func cornerPoints() -> [CGPoint] {
        let hw = width / 2, hh = height / 2
        let locals = [
            CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
            CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh),
        ]
        return locals.map { local in
            rotatePoint(CGPoint(x: center.x + local.x, y: center.y + local.y),
                        around: center, by: rotation)
        }
    }

    // MARK: Drawing

    /// Spotlight 不在常规 draw 中绘制遮罩；遮罩由 AnnotationView 统一处理。
    /// 仅绘制高亮边框。
    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 3])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(8)
        ctx.stroke(rect)
        ctx.restoreGState()
    }

    // MARK: Selection & Snap

    func selectionHandlePoints() -> [CGPoint] {
        cornerPoints()
    }

    func snapPoints() -> [SnapPoint] {
        var points = [SnapPoint(point: center, type: .center)]
        for corner in cornerPoints() {
            points.append(SnapPoint(point: corner, type: .corner))
        }
        return points
    }

    func nearestPerimeterPoint(to point: CGPoint) -> CGPoint {
        let localPt = rotatePoint(point, around: center, by: -rotation)
        let lx = localPt.x - center.x
        let ly = localPt.y - center.y
        let hw = width / 2, hh = height / 2
        let cx = max(-hw, min(hw, lx))
        let cy = max(-hh, min(hh, ly))
        var nearest: CGPoint
        if abs(cx) < hw && abs(cy) < hh {
            let dists = [cx + hw, hw - cx, cy + hh, hh - cy]
            let minD = dists.min()!
            if minD == dists[0] { nearest = CGPoint(x: -hw, y: cy) }
            else if minD == dists[1] { nearest = CGPoint(x: hw, y: cy) }
            else if minD == dists[2] { nearest = CGPoint(x: cx, y: -hh) }
            else { nearest = CGPoint(x: cx, y: hh) }
        } else {
            nearest = CGPoint(x: cx, y: cy)
        }
        return rotatePoint(CGPoint(x: center.x + nearest.x, y: center.y + nearest.y),
                           around: center, by: rotation)
    }

    // MARK: Transform

    func move(by delta: CGVector) {
        center.x += delta.dx
        center.y += delta.dy
    }

    func rotate(by angle: CGFloat) {
        rotation += angle
    }

    func scale(by factor: CGFloat) {
        width *= abs(factor)
        height *= abs(factor)
    }
}
