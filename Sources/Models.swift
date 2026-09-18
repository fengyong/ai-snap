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

// MARK: - Rect Perimeter

/// 矩形类形状的周长参数化。
///
/// 「参数 → 点」与「点 → 参数」是**互逆的一对**，必须用同一套分段反向。
/// 分成两份独立实现（一份在形状里、一份在附着判定里）的后果很隐蔽：
/// 箭头会吸附到与鼠标实际位置不符的地方，看起来像「箭头自己乱跳」。
/// 这里做成单一实现，让两者不一致这件事在结构上不可能发生。
///
/// 分段顺序：**下边（左→右）→ 右边（下→上）→ 上边（右→左）→ 左边（上→下）**，
/// 与 `RectangleShape` 一直以来的约定保持一致。
///
/// 矩形、贴纸（正方形）、文字标注三种形状共用。
enum RectPerimeter {

    /// 点 → 周长参数 (0...1)
    static func parameter(for point: CGPoint, center: CGPoint,
                          size: CGSize, rotation: CGFloat) -> CGFloat {
        let perimeter = 2 * (size.width + size.height)
        guard perimeter > 0 else { return 0 }

        // 先转到形状的局部坐标（把旋转消掉），再按轴对齐矩形判定
        let local = rotatePoint(point, around: center, by: -rotation)
        let lx = local.x - center.x
        let ly = local.y - center.y
        let hw = size.width / 2, hh = size.height / 2

        var d: CGFloat = 0
        if ly <= -hh + 0.1 { d = lx + hw }                                   // 下边
        else if lx >= hw - 0.1 { d = size.width + (ly + hh) }                // 右边
        else if ly >= hh - 0.1 { d = size.width + size.height + (hw - lx) }  // 上边
        else { d = 2 * size.width + size.height + (hh - ly) }                // 左边
        return max(0, min(1, d / perimeter))
    }

    /// 周长参数 (0...1) → 边界上的世界坐标点
    static func point(at parameter: CGFloat, center: CGPoint,
                      size: CGSize, rotation: CGFloat) -> CGPoint {
        let perimeter = 2 * (size.width + size.height)
        guard perimeter > 0 else { return center }

        let hw = size.width / 2, hh = size.height / 2
        let d = parameter * perimeter
        var local: CGPoint
        if d < size.width {
            local = CGPoint(x: -hw + d, y: -hh)                                  // 下边
        } else if d < size.width + size.height {
            local = CGPoint(x: hw, y: -hh + (d - size.width))                    // 右边
        } else if d < 2 * size.width + size.height {
            local = CGPoint(x: hw - (d - size.width - size.height), y: hh)       // 上边
        } else {
            local = CGPoint(x: -hw, y: hh - (d - 2 * size.width - size.height))  // 左边
        }
        return rotatePoint(CGPoint(x: center.x + local.x, y: center.y + local.y),
                           around: center, by: rotation)
    }
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
    case triangle   // 尾部箭头（实心）→ 与三角形头部组合即为双向箭头
    case open       // 尾部箭头（开放）

    /// 尾部为箭头样式时返回等价的头部类型，供复用头部绘制逻辑；否则返回 nil。
    var asArrowHead: ArrowHeadType? {
        switch self {
        case .triangle: return .triangle
        case .open:     return .open
        case .none, .circle, .perpendicular: return nil
        }
    }
}

/// 带 String 原始值：便于持久化（见 `Preferences.lineStyle`），
/// 也便于把「存储值」与「枚举顺序」解耦 —— 将来插入新 case 不会让老用户的已存值错位。
enum LineStyle: String, CaseIterable {
    case solid
    case dashed
    case dotted

    var displayName: String {
        switch self {
        case .solid: return "实线"
        case .dashed: return "虚线"
        case .dotted: return "点线"
        }
    }

    /// 按线型设置 dash 与线帽。
    ///
    /// **dash 长度必须随线宽缩放，且虚线要用平头（.butt）**，否则间隙会被线帽吞掉：
    /// 圆头（.round）会让每段 dash 两端各外扩 `lineWidth / 2`，
    /// 实际覆盖长度变成 `dash + lineWidth`。原实现固定用 `[8, 4]` + 圆头，
    /// 当线宽 ≥ 4 时（默认线宽 15）覆盖长度 8 + 15 = 23 > 周期 12，
    /// **相邻 dash 完全重叠 —— 「虚线」「点菱」两种预设画出来与实线毫无区别。**
    ///
    /// 现值经离屏实测：虚线在 1–30 的全部线宽下均保持约 40% 的空隙占比。
    ///
    /// 箭头的箭身、矩形、椭圆共用本方法，保证线型在各形状上表现一致。
    /// **命中检测（`drawHitTest`）不要调用它** —— 见 `Arrow.drawHitTest` 的说明。
    func apply(lineWidth lw: CGFloat, in ctx: CGContext) {
        switch self {
        case .solid:
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineCap(.round)
        case .dashed:
            // 平头 + [3w, 2w]（业界惯例）
            ctx.setLineDash(phase: 0, lengths: [lw * 3, lw * 2])
            ctx.setLineCap(.butt)
        case .dotted:
            // 圆头 + 极短 dash = 圆点；间隙需大于线宽才可见
            ctx.setLineDash(phase: 0, lengths: [1, lw * 2])
            ctx.setLineCap(.round)
        }
    }
}

/// 支持线型（实线/虚线/点线）的标注对象。
///
/// 单独抽协议而不是塞进 `AnnotationObject`：箭头把线型放在 `ArrowStyle` 里，
/// 序号/贴纸/聚光灯则根本没有「描边线型」这个概念，加进主协议会逼每个类型
/// 都实现一遍（且多半只能写成空实现）。
protocol LineStyleSupporting: AnyObject {
    var lineStyle: LineStyle { get set }
}

/// `Equatable` 是为了让 `Preferences` 能按值反查预设下标（存下标比存整个结构稳）。
struct ArrowStyle: Equatable {
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

    /// 双向箭头（两端都是实心三角）
    static let doubleArrow = ArrowStyle(
        headType: .triangle, tailType: .triangle, lineStyle: .solid,
        headLength: 14, headAngle: .pi / 6
    )

    /// 双向箭头（两端都是开放样式）
    static let doubleOpenArrow = ArrowStyle(
        headType: .open, tailType: .open, lineStyle: .solid,
        headLength: 14, headAngle: .pi / 6
    )

    static let allPresets: [ArrowStyle] = [
        .default, .openArrow, .dashedArrow, .diamondArrow,
        .circleEndpoints, .dottedDiamond, .doubleArrow, .doubleOpenArrow
    ]

    static let presetNames: [String] = [
        "实心", "开放", "虚线", "菱形", "圆端", "点菱", "双向", "双开放"
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

/// 移动箭头时会解除它的附着关系；这里保存解除前的状态，好让撤销能真正还原
struct DetachedAttachments {
    let key: UInt32
    let start: Attachment?
    let end: Attachment?
}

enum UndoAction {
    /// 添加了一个对象（撤销 = 删除它）
    case add(colorKey: UInt32)
    /// 删除了对象（撤销 = 重新添加，包含被级联删除的子箭头）
    case delete(objects: [(UInt32, any AnnotationObject)], zOrderSnapshot: [UInt32])
    /// 移动了对象（撤销 = 反向移动）；`detached` 记录被解除的附着，撤销时一并恢复
    case move(colorKey: UInt32, delta: CGVector, detached: DetachedAttachments?)
    /// 旋转了对象
    case rotate(colorKey: UInt32, angle: CGFloat)
    /// 缩放了对象
    case scale(colorKey: UInt32, factor: CGFloat)
    /// 改了文字标注的内容（撤销 = 改回 previous）
    case editText(colorKey: UInt32, previous: String)
}

// MARK: - Cyclic Index

/// 在长度为 `count` 的列表里循环步进下标。
///
/// 抽成独立纯函数是为了**能离屏测试**：环绕边界（首尾相接、反向跨零、`current` 为 nil）
/// 是最容易写错的一类算术，而它原本藏在 `AnnotationWindow` 里 ——
/// 那是个需要真实窗口才能实例化的 UI 类，测不到。
///
/// 注意负数取模：Swift 的 `%` 对负数返回负数（`-1 % 7 == -1`），
/// 所以反向步进必须再加一次 `count` 再取模。
enum CyclicIndex {
    /// - Parameter current: 当前下标；`nil` 表示当前项不在列表里。
    /// - Returns: 步进后的下标。`count <= 0` 时返回 0。
    static func step(_ current: Int?, count: Int, reverse: Bool = false) -> Int {
        guard count > 0 else { return 0 }
        guard let current = current else {
            // 当前项不在列表里：正向从头开始，反向从尾开始
            return reverse ? count - 1 : 0
        }
        let delta = reverse ? -1 : 1
        let raw = current + delta
        return ((raw % count) + count) % count
    }
}

// MARK: - Drawing Tool & Canvas State

enum DrawingTool: Equatable {
    case arrow
    case rectangle
    case roundedRectangle   // 圆角矩形（与 rectangle 同一个形状类，只是 cornerRadius > 0）
    case circle    // 正圆（radiusX == radiusY）
    case ellipse   // 椭圆（独立 radiusX / radiusY）
    case stamp(StampType)
    case step      // 序号标注（单击放置，编号自动递增）
    case text      // 文字标注（单击放置后原地输入）
    case spotlight
    case mosaic    // 马赛克打码（拖拽框选）
    case blur      // 高斯模糊打码（拖拽框选）
    case eraser    // 橡皮擦：拖拽抹掉经过的对象，本身不产生对象
    case picker    // 取色器：从截图上取色，本身不产生对象

    static func == (lhs: DrawingTool, rhs: DrawingTool) -> Bool {
        switch (lhs, rhs) {
        case (.arrow, .arrow), (.rectangle, .rectangle),
             (.roundedRectangle, .roundedRectangle),
             (.circle, .circle), (.ellipse, .ellipse),
             (.step, .step), (.text, .text), (.spotlight, .spotlight),
             (.mosaic, .mosaic), (.blur, .blur), (.eraser, .eraser),
             (.picker, .picker):
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
    /// 橡皮擦拖拽中。它不是"正在画某个对象"，而是一边拖一边删，所以单独一个状态 ——
    /// 整条拖拽路径上的删除最后合成**一步撤销**（否则按一次 ⌘Z 只撤销掉抹掉的一个对象，
    /// 想退回原状得按十几次）。
    case erasing
    /// 取色器拖拽中。与橡皮擦同理：它也不产生对象，而是持续读取光标处的像素。
    case picking
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

    /// 导出（保存 PNG / 复制到剪贴板）时绘制对象本体。
    ///
    /// 默认与 `draw(in:)` 完全一致；只有"纯编辑器 UI"需要覆写它把自己排除掉。
    /// 单列一个方法而不是加 `forExport:` 参数：这样新增图形类型什么都不用做，
    /// 只有需要区分导出行为的类型才多写一个方法。
    func drawForExport(in ctx: CGContext)

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

extension AnnotationObject {
    /// 默认：导出与屏幕所见一致
    func drawForExport(in ctx: CGContext) { draw(in: ctx) }
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
        // picking pass 必须画实线，不能继承视觉层的虚线样式。
        // 否则虚线产生的空隙会让「点在空隙上」时选不中该箭头；
        // 业界标准做法就是 picking pass 永远不继承 dash。
        drawArrow(in: ctx, withColor: color, lw: lineWidth + 6, forceSolid: true)
    }

    private func drawArrow(in ctx: CGContext, withColor drawColor: NSColor,
                           lw: CGFloat, forceSolid: Bool = false) {
        ctx.setStrokeColor(drawColor.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineJoin(.round)

        if forceSolid {
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: [])
        } else {
            style.lineStyle.apply(lineWidth: lw, in: ctx)
        }

        // Shaft
        ctx.move(to: startPoint)
        ctx.addLine(to: endPoint)
        ctx.strokePath()

        // 头部/尾部一律用实线 + 圆头（虚线只作用于箭身）
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineCap(.round)

        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)

        // 头部（箭头指向 endPoint）
        drawHead(style.headType, at: endPoint, angle: angle, in: ctx, color: drawColor)

        // 尾部
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
        case .triangle, .open:
            // 尾部箭头：复用头部绘制，方向反转 180° 使其指向 startPoint
            if let headType = style.tailType.asArrowHead {
                drawHead(headType, at: startPoint, angle: angle + .pi,
                         in: ctx, color: drawColor)
            }
        }
    }

    /// 在指定端点绘制箭头头部。`angle` 是箭头指向的方向（弧度）。
    ///
    /// 头尾共用本方法：头部传 `angle`，尾部传 `angle + π`。
    private func drawHead(_ type: ArrowHeadType, at tip: CGPoint, angle: CGFloat,
                          in ctx: CGContext, color drawColor: NSColor) {
        let len = style.headLength
        let spread = style.headAngle

        switch type {
        case .triangle:
            let p1 = CGPoint(x: tip.x - len * cos(angle - spread),
                             y: tip.y - len * sin(angle - spread))
            let p2 = CGPoint(x: tip.x - len * cos(angle + spread),
                             y: tip.y - len * sin(angle + spread))
            ctx.setFillColor(drawColor.cgColor)
            ctx.move(to: tip)
            ctx.addLine(to: p1)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.fillPath()

        case .open:
            let p1 = CGPoint(x: tip.x - len * cos(angle - spread),
                             y: tip.y - len * sin(angle - spread))
            let p2 = CGPoint(x: tip.x - len * cos(angle + spread),
                             y: tip.y - len * sin(angle + spread))
            ctx.move(to: p1)
            ctx.addLine(to: tip)
            ctx.addLine(to: p2)
            ctx.strokePath()

        case .diamond:
            let mid = CGPoint(x: tip.x - len * 0.5 * cos(angle),
                              y: tip.y - len * 0.5 * sin(angle))
            let p1 = CGPoint(x: mid.x - len * 0.4 * cos(angle - .pi / 2),
                             y: mid.y - len * 0.4 * sin(angle - .pi / 2))
            let p2 = CGPoint(x: mid.x + len * 0.4 * cos(angle - .pi / 2),
                             y: mid.y + len * 0.4 * sin(angle - .pi / 2))
            let back = CGPoint(x: tip.x - len * cos(angle),
                               y: tip.y - len * sin(angle))
            ctx.setFillColor(drawColor.cgColor)
            ctx.move(to: tip)
            ctx.addLine(to: p1)
            ctx.addLine(to: back)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.fillPath()

        case .none:
            break
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

class RectangleShape: AnnotationObject, LineStyleSupporting {
    let id: UUID
    let hitTestColorKey: UInt32
    var center: CGPoint
    var width: CGFloat
    var height: CGFloat
    var rotation: CGFloat
    var color: NSColor
    var lineWidth: CGFloat
    /// 描边线型（实线/虚线/点线）。新建对象时由画布按当前工具设置写入。
    var lineStyle: LineStyle = .solid
    /// 圆角半径，0 = 直角矩形。
    /// 圆角矩形与直角矩形共用本类，只是这个值不同 —— 于是旋转、缩放、吸附、
    /// 撤销重做、线型全部自动共用，不必再写一个新形状类。
    var cornerRadius: CGFloat = 0

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
        ctx.setLineJoin(.round)
        lineStyle.apply(lineWidth: lineWidth, in: ctx)
        if cornerRadius > 0 {
            // 半径上限取短边一半：超出时 CGPath 的圆角会彼此挤压、形状失真
            let r = min(cornerRadius, min(width, height) / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r,
                               transform: nil))
            ctx.strokePath()
        } else {
            ctx.stroke(rect)
        }
        ctx.restoreGState()
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        // 命中区刻意用「直角矩形」而不是圆角路径：
        // 圆角路径内切于直角矩形，用直角判定得到的命中区是视觉的**超集** ——
        // 圆角处点到边角外侧的空白也能选中，比反过来「看得见却点不中」更友好。
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth + 6)
        // 命中检测强制实线：虚线/点线的空隙会让点击落在空处、选不中该对象
        // （与 Arrow.drawHitTest 一致 —— picking pass 不继承 dash 是业界惯例）
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineCap(.round)
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
        RectPerimeter.point(at: parameter, center: center,
                            size: CGSize(width: width, height: height),
                            rotation: rotation)
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

// MARK: - CircleShape (Ellipse)

class CircleShape: AnnotationObject, LineStyleSupporting {
    let id: UUID
    let hitTestColorKey: UInt32
    var center: CGPoint
    var radiusX: CGFloat
    var radiusY: CGFloat
    var rotation: CGFloat
    var color: NSColor
    var lineWidth: CGFloat
    /// 描边线型（实线/虚线/点线）。新建对象时由画布按当前工具设置写入。
    var lineStyle: LineStyle = .solid

    init(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, color: NSColor,
         lineWidth: CGFloat = 2.0, hitTestColorKey: UInt32) {
        self.id = UUID()
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.rotation = 0
        self.color = color
        self.lineWidth = lineWidth
        self.hitTestColorKey = hitTestColorKey
    }

    var boundingBox: CGRect {
        // 旋转后的包围盒
        let cosR = abs(cos(rotation)), sinR = abs(sin(rotation))
        let hw = radiusX * cosR + radiusY * sinR + lineWidth
        let hh = radiusX * sinR + radiusY * cosR + lineWidth
        return CGRect(x: center.x - hw, y: center.y - hh, width: hw * 2, height: hh * 2)
    }

    /// 4 quadrant points on the ellipse
    func quadrantPoints() -> [CGPoint] {
        [CGFloat(0), .pi / 2, .pi, 3 * .pi / 2].map { a in
            let localX = radiusX * cos(a)
            let localY = radiusY * sin(a)
            return rotatePoint(CGPoint(x: center.x + localX, y: center.y + localY),
                               around: center, by: rotation)
        }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let rect = CGRect(x: -radiusX, y: -radiusY, width: radiusX * 2, height: radiusY * 2)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        lineStyle.apply(lineWidth: lineWidth, in: ctx)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let rect = CGRect(x: -radiusX, y: -radiusY, width: radiusX * 2, height: radiusY * 2)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth + 6)
        // 命中检测强制实线（同 RectangleShape.drawHitTest）
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineCap(.round)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()
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
        // 转换到局部坐标
        let local = rotatePoint(point, around: center, by: -rotation)
        let dx = local.x - center.x
        let dy = local.y - center.y
        // 椭圆上最近点的近似：沿方向射线与椭圆的交点
        let dist = hypot(dx / radiusX, dy / radiusY)
        guard dist > 0 else {
            return rotatePoint(CGPoint(x: center.x + radiusX, y: center.y),
                               around: center, by: rotation)
        }
        let nx = dx / dist
        let ny = dy / dist
        let localNearest = CGPoint(x: center.x + radiusX * nx, y: center.y + radiusY * ny)
        return rotatePoint(localNearest, around: center, by: rotation)
    }

    /// 周长参数 (0...1) → 椭圆周上的世界坐标点
    func pointOnPerimeter(at parameter: CGFloat) -> CGPoint {
        let angle = parameter * 2 * .pi
        let localX = radiusX * cos(angle)
        let localY = radiusY * sin(angle)
        return rotatePoint(CGPoint(x: center.x + localX, y: center.y + localY),
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
        radiusX *= abs(factor)
        radiusY *= abs(factor)
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
        // All stamps: filled bounding rect for hit test, with extra padding for easier selection
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let half = size / 2 + 8
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: -half, y: -half, width: half * 2, height: half * 2))
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
        // 正方形 → 尺寸就是边长；与「点 → 参数」共用 RectPerimeter 的同一套分段
        RectPerimeter.point(at: parameter, center: center,
                            size: CGSize(width: size, height: size),
                            rotation: rotation)
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

// MARK: - StepBadge

/// 序号标注：圆形底 + 居中数字，用于步骤说明（Step 1 / 2 / 3）。
///
/// 因为命中检测走 Layer B 的像素读取，本类只需正确实现 `drawHitTest`，
/// 选中 / 移动 / 旋转 / 缩放 / 撤销重做会全部自动继承，无额外代码。
class StepBadge: AnnotationObject {
    let id: UUID
    let hitTestColorKey: UInt32
    var center: CGPoint
    var radius: CGFloat
    var rotation: CGFloat
    var color: NSColor
    /// 显示的数字。由调用方（AnnotationView）在创建时分配
    var number: Int

    init(center: CGPoint, number: Int, radius: CGFloat = 18,
         color: NSColor = .systemRed, rotation: CGFloat = 0,
         hitTestColorKey: UInt32) {
        self.id = UUID()
        self.center = center
        self.number = number
        self.radius = radius
        self.rotation = rotation
        self.color = color
        self.hitTestColorKey = hitTestColorKey
    }

    var boundingBox: CGRect {
        let half = radius + 2
        return CGRect(x: center.x - half, y: center.y - half,
                      width: half * 2, height: half * 2)
    }

    // MARK: Drawing

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)

        // 圆形底
        let rect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)

        // 居中数字（沿用 StampObject.drawEmoji 的文本绘制方式）
        let font = NSFont.systemFont(ofSize: radius * 1.25, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let text = "\(number)" as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2),
                  withAttributes: attrs)

        ctx.restoreGState()
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        // 用外接正方形填充，比圆形更容易点中
        let half = radius + 6
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: -half, y: -half, width: half * 2, height: half * 2))
        ctx.restoreGState()
    }

    // MARK: Selection & Snap

    func selectionHandlePoints() -> [CGPoint] {
        let half = radius
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
        let r = radius
        let distance = hypot(lx, ly)
        guard distance > 0 else {
            return rotatePoint(CGPoint(x: center.x + r, y: center.y),
                               around: center, by: rotation)
        }
        let nearest = CGPoint(x: center.x + r * lx / distance,
                              y: center.y + r * ly / distance)
        return rotatePoint(nearest, around: center, by: rotation)
    }

    /// 周长参数 (0...1) → 圆周上的世界坐标点
    func pointOnPerimeter(at parameter: CGFloat) -> CGPoint {
        let angle = parameter * 2 * .pi - .pi / 2
        let local = CGPoint(x: center.x + radius * cos(angle),
                            y: center.y + radius * sin(angle))
        return rotatePoint(local, around: center, by: rotation)
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
        radius = max(radius * abs(factor), 6)
    }
}

// MARK: - TextShape

/// 文字标注。
///
/// **尺寸由文字内容与字号推导，不单独存宽高**：改字号、改文字之后，
/// 包围盒 / 命中区 / 选择手柄会自动跟着变。若额外存一份宽高，就得在
/// 「改文字」「改字号」「缩放」三处都记得同步，漏一处就出 bug。
final class TextShape: AnnotationObject {
    let id: UUID
    let hitTestColorKey: UInt32
    var center: CGPoint
    var text: String
    var fontSize: CGFloat
    var rotation: CGFloat
    var color: NSColor

    /// 文字四周的留白（点）。给一点留白，免得命中区紧贴字边难点击。
    static let padding: CGFloat = 4

    init(center: CGPoint, text: String, fontSize: CGFloat = 20,
         color: NSColor = .systemRed, rotation: CGFloat = 0,
         hitTestColorKey: UInt32) {
        self.id = UUID()
        self.hitTestColorKey = hitTestColorKey
        self.center = center
        self.text = text
        self.fontSize = fontSize
        self.rotation = rotation
        self.color = color
    }

    var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }

    /// 绘制与测量共用同一份属性 —— 这是「量出来的框」和「画出来的字」能对齐的前提。
    /// 两边各写一份字体/段落设置，迟早会漂移。
    var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// 内容尺寸（含留白）。多行文字由 NSString 的 size(withAttributes:) 自动计入行数。
    var contentSize: CGSize {
        let raw = (text as NSString).size(withAttributes: attributes)
        return CGSize(width: ceil(raw.width) + Self.padding * 2,
                      height: ceil(raw.height) + Self.padding * 2)
    }

    var boundingBox: CGRect {
        let corners = selectionHandlePoints()
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            let size = contentSize
            return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        // 旋转后取外接矩形，避免手柄跑到框外
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Drawing

    func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)

        let size = contentSize
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2,
                          width: size.width, height: size.height)
        // 用 draw(in:) 而不是 draw(at:)：前者能正确处理多行与居中，
        // 且在非翻转坐标系下的位置也是对的
        (text as NSString).draw(in: rect.insetBy(dx: Self.padding, dy: Self.padding),
                                withAttributes: attributes)

        ctx.restoreGState()
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let size = contentSize
        ctx.setFillColor(color.cgColor)
        // 外扩 6 点：文字笔画细，紧贴字边很难点中
        ctx.fill(CGRect(x: -size.width / 2 - 6, y: -size.height / 2 - 6,
                        width: size.width + 12, height: size.height + 12))
        ctx.restoreGState()
    }

    // MARK: Selection & Snap

    func selectionHandlePoints() -> [CGPoint] {
        let size = contentSize
        let hw = size.width / 2, hh = size.height / 2
        let locals = [
            CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
            CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh),
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
        let local = rotatePoint(point, around: center, by: -rotation)
        let size = contentSize
        let hw = size.width / 2, hh = size.height / 2
        let clamped = CGPoint(x: min(max(local.x, center.x - hw), center.x + hw),
                              y: min(max(local.y, center.y - hh), center.y + hh))
        return rotatePoint(clamped, around: center, by: rotation)
    }

    /// 周长参数 (0...1) → 矩形边界上的世界坐标点。
    ///
    /// 与「点 → 参数」共用 `RectPerimeter` 的同一套分段 —— 两者是互逆的一对，
    /// 各写一份会让箭头吸附到错的位置。
    func pointOnPerimeter(at parameter: CGFloat) -> CGPoint {
        RectPerimeter.point(at: parameter, center: center,
                            size: contentSize, rotation: rotation)
    }

    // MARK: Transform

    func move(by delta: CGVector) {
        center.x += delta.dx
        center.y += delta.dy
    }

    func rotate(by angle: CGFloat) {
        rotation += angle
    }

    /// 缩放作用在**字号**上 —— 文字的「大小」就是字号，改宽高没有意义
    func scale(by factor: CGFloat) {
        fontSize = min(max(fontSize * abs(factor), 8), 300)
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
        let corners = cornerPoints()
        let xs = corners.map { $0.x }
        let ys = corners.map { $0.y }
        let padding: CGFloat = 2 // stroke width used in draw()
        return CGRect(x: xs.min()! - padding, y: ys.min()! - padding,
                      width: (xs.max()! - xs.min()!) + padding * 2,
                      height: (ys.max()! - ys.min()!) + padding * 2)
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
        // 边框保持黄色：`color` 在 SpotlightShape 里的默认值是"带 alpha 的黑"，
        // 语义是**遮罩浓淡**（见 drawSpotlightOverlay），不是边框色。
        // 若把边框也接到 color 上，默认聚光灯的虚线会变成黑色，
        // 失去"这里有一块高亮"的辨识度。
        ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 3])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 导出时**只保留遮罩，不画边框**。
    ///
    /// 这条虚线是"这里有个聚光灯、可以点它选中"的编辑器提示，属于 UI 而不属于
    /// 标注内容；拍进 PNG 会让用户拿到的图多一圈黄框。
    /// 遮罩本身由 `AnnotationView.drawSpotlightOverlay` 统一绘制，这里什么都不做。
    func drawForExport(in ctx: CGContext) {}

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
