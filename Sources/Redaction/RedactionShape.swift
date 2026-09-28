import Cocoa

/// 打码方式。
///
/// 两种打码共用一个形状类（`RedactionShape`），只是这里不同 —— 于是旋转、缩放、
/// 吸附、撤销重做、选择手柄全部自动共用，不必写两个形状类。
/// 这与「圆角矩形复用 `RectangleShape` + `cornerRadius`」是同一个取舍。
enum RedactionStyle: Equatable {
    /// 马赛克。`blockSize` 以**画布点**为单位（会按像素倍率换算）。
    case mosaic(blockSize: CGFloat)
    /// 高斯模糊。`radius` 以**画布点**为单位。
    case blur(radius: CGFloat)
}

/// 打码标注：把底图的一块区域替换成马赛克或模糊。
///
/// ## 为什么它不是「描边形状」
///
/// 它不往画布上画颜色，而是**读底图像素、处理后画回去**。因此它需要一个别的形状
/// 都不需要的东西：底图本身（`sourceImage`）。
///
/// ## 取样区域用「外接矩形」而不是「形状自身」
///
/// 取样永远取一块**轴对齐**的区域（形状旋转后的外接矩形），绘制时再用形状自身的
/// 路径裁剪。这样：
/// - 不旋转时外接矩形就是形状本身，与直觉一致；
/// - 旋转后，被覆盖的区域仍然**完整**（不存在漏打码），而且显示的像素来自正确的
///   位置 —— 若改成「把取样块跟着一起旋转」，模糊区会显示来自别处的画面。
///
/// ## 缓存
///
/// 打码结果按「取样矩形 + 样式 + 像素倍率」缓存，且在 `draw` 时比对缓存键自动失效 ——
/// **不需要在 move/scale/rotate 里逐个挂钩子**。挂钩子的写法漏一处就是「拖完还是旧的
/// 打码」，而且没有任何报错。
final class RedactionShape: AnnotationObject {
    let id = UUID()
    let hitTestColorKey: UInt32

    var center: CGPoint
    var width: CGFloat
    var height: CGFloat
    var rotation: CGFloat = 0
    /// 协议要求有颜色；打码不使用描边色，保留是为了与其它对象统一（也便于将来加"打码边框提示"）
    var color: NSColor = .clear

    var style: RedactionStyle

    /// 要读取的底图。由画布在创建时注入；同一次会话内不变（底图是冻结帧）。
    var sourceImage: CGImage?
    /// 「画布点 → 底图像素」的倍率。马赛克块大小与模糊半径都要乘上它，
    /// 否则 Retina 上块会小一半、模糊程度也只有一半。
    var pixelScale: CGFloat = 1

    init(center: CGPoint, width: CGFloat, height: CGFloat,
         style: RedactionStyle, hitTestColorKey: UInt32) {
        self.center = center
        self.width = width
        self.height = height
        self.style = style
        self.hitTestColorKey = hitTestColorKey
    }

    /// 由两点拖拽创建（对角）
    convenience init(from pointA: CGPoint, to pointB: CGPoint,
                     style: RedactionStyle, hitTestColorKey: UInt32) {
        self.init(center: CGPoint(x: (pointA.x + pointB.x) / 2,
                                  y: (pointA.y + pointB.y) / 2),
                  width: abs(pointB.x - pointA.x),
                  height: abs(pointB.y - pointA.y),
                  style: style,
                  hitTestColorKey: hitTestColorKey)
    }

    // MARK: - 几何

    func cornerPoints() -> [CGPoint] {
        let hw = width / 2, hh = height / 2
        let locals = [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
                      CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
        return locals.map {
            rotatePoint(CGPoint(x: center.x + $0.x, y: center.y + $0.y),
                        around: center, by: rotation)
        }
    }

    /// 形状自身（可能已旋转）的矩形路径 —— 绘制时用它裁剪。
    private func shapePath() -> CGPath {
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: rotation)
        return CGPath(rect: rect, transform: &transform)
    }

    /// 取样区域 = 形状旋转后的**外接矩形**（画布坐标，轴对齐）。
    var sampleRect: CGRect {
        return enclosingBox(of: cornerPoints(), padding: 0) ?? .zero
    }

    var boundingBox: CGRect {
        sampleRect.insetBy(dx: -1, dy: -1)
    }

    // MARK: - 绘制

    func draw(in ctx: CGContext) {
        let target = sampleRect.integral
        ctx.saveGState()
        ctx.addPath(shapePath())
        ctx.clip()
        if let patch = redactionImage(for: target) {
            // 贴图已经是画布点分辨率 → 1:1 贴上，不做任何缩放、不用插值
            ctx.interpolationQuality = .none
            ctx.draw(patch, in: target)
        } else {
            // 没有底图（离屏构造、或裁剪失败）时退化为中性灰块：
            // 宁可看得见"这里被打码了"，也不要静默什么都不画
            ctx.setFillColor(NSColor.systemGray.withAlphaComponent(0.75).cgColor)
            ctx.fill(target)
        }
        ctx.restoreGState()
    }

    func drawHitTest(in ctx: CGContext, color: NSColor) {
        // 打码是实心的 —— 命中区就是整块，直接填充（其它形状是描边，所以用 stroke）
        ctx.saveGState()
        ctx.addPath(shapePath())
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// 打码图（带自失效缓存）。取不到底图时返回 nil，由 `draw` 退化为灰块。
    private func redactionImage(for rect: CGRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        let key = CacheKey(rect: rect, style: style, pixelScale: pixelScale,
                           sourceWidth: sourceImage?.width ?? 0)
        if let cached = cache, cached.key == key { return cached.image }
        guard let built = buildRedaction(for: rect) else { return nil }
        cache = (key, built)
        return built
    }

    private struct CacheKey: Equatable {
        let rect: CGRect
        let style: RedactionStyle
        let pixelScale: CGFloat
        let sourceWidth: Int
    }

    private var cache: (key: CacheKey, image: CGImage)?

    /// 生成打码贴图，尺寸为**画布点分辨率**（`draw` 时 1:1 贴上）。
    private func buildRedaction(for rect: CGRect) -> CGImage? {
        guard let source = sourceImage else { return nil }
        let imageSize = CGSize(width: source.width, height: source.height)
        // 画布点 → 底图像素：复用与「选区裁剪」同一套换算（缩放反推 + Y 翻转）。
        // 自己再写一遍翻转公式是最容易出错的地方 —— 而写错的表现只是「马赛克盖在
        // 稍微偏上的位置」，不盯着看根本发现不了。
        let canvasSize = CGSize(width: imageSize.width / max(pixelScale, 0.01),
                                height: imageSize.height / max(pixelScale, 0.01))
        let pixelRect = ScreenGeometry.pixelRect(
            appKitRect: rect,
            imageSize: imageSize,
            appKitScreenFrame: CGRect(origin: .zero, size: canvasSize)
        )
        guard !pixelRect.isNull else { return nil }

        switch style {
        case .mosaic(let blockSize):
            guard let crop = source.cropping(to: pixelRect) else { return nil }
            let blockPixels = max(2, Int((blockSize * pixelScale).rounded()))
            guard let blocks = ImageRedaction.blockAverages(crop, blockSize: blockPixels)
            else { return nil }
            // 最近邻放大 → 硬边色块。用高质量插值会把刚做出来的块又糊回去。
            return ImageRedaction.scale(blocks, to: rect.size, quality: .none)

        case .blur(let radius):
            let radiusPixels = max(1, radius * pixelScale)
            // 向外多取 3×半径再模糊、然后裁回原范围。只裁原范围的话，模糊核在边缘
            // 只能取到钳制后的边缘像素，四周会出现一圈「和别处不一样」的晕边，
            // 区域越小越明显。
            let pad = Int((radiusPixels * 3).rounded(.up))
            let expanded = pixelRect.insetBy(dx: -CGFloat(pad), dy: -CGFloat(pad))
                .intersection(CGRect(origin: .zero, size: imageSize)).integral
            guard !expanded.isNull, expanded.width >= 1, expanded.height >= 1,
                  let wide = source.cropping(to: expanded),
                  let blurred = ImageRedaction.blur(wide, radius: radiusPixels) else {
                return nil
            }
            // 裁回原区域 —— 裁切坐标相对 expanded 的左上角（CGImage 的裁剪是左上原点）
            let inner = CGRect(x: pixelRect.minX - expanded.minX,
                               y: pixelRect.minY - expanded.minY,
                               width: pixelRect.width,
                               height: pixelRect.height).integral
            guard inner.width >= 1, inner.height >= 1,
                  let region = blurred.cropping(to: inner) else { return nil }
            // 模糊图缩到点分辨率用 `.medium`（精确面积平均）：`.high` 是带振铃的
            // Lanczos，在模糊图上虽然看不出振铃，但会引入一圈比周围更亮的边。
            return ImageRedaction.scale(region, to: rect.size, quality: .medium)
        }
    }

    // MARK: - 选中与吸附

    func selectionHandlePoints() -> [CGPoint] { cornerPoints() }

    func snapPoints() -> [SnapPoint] {
        var points = [SnapPoint(point: center, type: .center)]
        for corner in cornerPoints() {
            points.append(SnapPoint(point: corner, type: .corner))
        }
        return points
    }

    func nearestPerimeterPoint(to point: CGPoint) -> CGPoint {
        RectPerimeter.nearestPoint(to: point, center: center,
                                   size: CGSize(width: width, height: height),
                                   rotation: rotation)
    }

    func pointOnPerimeter(at parameter: CGFloat) -> CGPoint {
        RectPerimeter.point(at: parameter, center: center,
                            size: CGSize(width: width, height: height), rotation: rotation)
    }

    func perimeterParameter(for point: CGPoint) -> CGFloat {
        RectPerimeter.parameter(for: point, center: center,
                                size: CGSize(width: width, height: height), rotation: rotation)
    }

    // MARK: - 变换

    func move(by delta: CGVector) {
        center.x += delta.dx
        center.y += delta.dy
    }

    func rotate(by angle: CGFloat) {
        rotation += angle
    }

    func scale(by factor: CGFloat) {
        let f = abs(factor)
        width = Self.scaledExtent(width, by: f)
        height = Self.scaledExtent(height, by: f)
    }
}
