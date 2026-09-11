import Cocoa

// MARK: - Object Snap

/// 吸附（snap）与相关的画布叠加绘制。
///
/// 拆到独立文件的原因：吸附是一个**只读取对象表、返回一个点**的纯查询，
/// 与鼠标状态机、撤销栈都没有耦合 —— 它唯一的外部依赖是 `objects` 与
/// `snapThreshold`。附带把两个「画在内容之上的叠加层」（吸附指示器、
/// 聚光灯遮罩）也放这里，因为它们都是纯绘制、不改状态。
extension AnnotationView {

    /// 查找距离 cursor 最近的吸附点（排除指定对象自身）
    func findNearestSnapPoint(to cursor: CGPoint, excludeKey: UInt32?) -> SnapPoint? {
        var bestDist: CGFloat = snapThreshold
        var bestSnap: SnapPoint?

        for (key, obj) in objects {
            if key == excludeKey { continue }
            for snap in obj.snapPoints() {
                let dist = hypot(cursor.x - snap.point.x, cursor.y - snap.point.y)
                if dist < bestDist {
                    bestDist = dist
                    bestSnap = snap
                }
            }
        }
        return bestSnap
    }

    /// 对一个点应用吸附，返回吸附后的点。
    ///
    /// 副作用是把命中的吸附点记进 `activeSnapPoint`（供绘制指示器用），
    /// 未命中时清空 —— 所以每次调用都会重置这个状态，不会残留上一次的高亮。
    func applySnap(to point: CGPoint, excludeKey: UInt32?) -> CGPoint {
        if let snap = findNearestSnapPoint(to: point, excludeKey: excludeKey) {
            activeSnapPoint = snap.point
            return snap.point
        }
        activeSnapPoint = nil
        return point
    }

    /// 绘制吸附指示器（十字 + 菱形）
    func drawSnapIndicator(at point: CGPoint, in ctx: CGContext) {
        let size: CGFloat = 8
        ctx.setStrokeColor(NSColor.systemCyan.cgColor)
        ctx.setLineWidth(1.5)

        // 十字线
        ctx.move(to: CGPoint(x: point.x - size, y: point.y))
        ctx.addLine(to: CGPoint(x: point.x + size, y: point.y))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: point.x, y: point.y - size))
        ctx.addLine(to: CGPoint(x: point.x, y: point.y + size))
        ctx.strokePath()

        // 菱形
        ctx.move(to: CGPoint(x: point.x, y: point.y - size * 0.6))
        ctx.addLine(to: CGPoint(x: point.x + size * 0.6, y: point.y))
        ctx.addLine(to: CGPoint(x: point.x, y: point.y + size * 0.6))
        ctx.addLine(to: CGPoint(x: point.x - size * 0.6, y: point.y))
        ctx.closePath()
        ctx.strokePath()
    }

    /// 绘制 Spotlight 遮罩：全图半透明遮盖，挖空所有 SpotlightShape 区域。
    ///
    /// 两个步骤都依赖变换后的圆角路径（对象可能被旋转过），所以路径是逐对象现算的，
    /// 不能预先合并成一个静态路径。
    func drawSpotlightOverlay(in ctx: CGContext) {
        var spotlights: [SpotlightShape] = []
        for key in zOrder {
            if let spot = objects[key] as? SpotlightShape {
                spotlights.append(spot)
            }
        }
        guard !spotlights.isEmpty else { return }

        let imageRect = CGRect(origin: .zero, size: baseImage.size)

        // 1. 周围区域变暗（even-odd 挖空高亮区域）
        ctx.saveGState()
        let fullPath = CGMutablePath()
        fullPath.addRect(imageRect)
        for spot in spotlights {
            var transform = CGAffineTransform.identity
                .translatedBy(x: spot.center.x, y: spot.center.y)
                .rotated(by: spot.rotation)
            let localRect = CGRect(x: -spot.width / 2, y: -spot.height / 2,
                                   width: spot.width, height: spot.height)
            let roundedPath = CGPath(roundedRect: localRect,
                                     cornerWidth: spot.cornerRadius,
                                     cornerHeight: spot.cornerRadius,
                                     transform: &transform)
            fullPath.addPath(roundedPath)
        }
        ctx.addPath(fullPath)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(imageRect)
        ctx.restoreGState()

        // 2. 高亮区域提亮（白色半透明叠加）
        for spot in spotlights {
            ctx.saveGState()
            var transform = CGAffineTransform.identity
                .translatedBy(x: spot.center.x, y: spot.center.y)
                .rotated(by: spot.rotation)
            let localRect = CGRect(x: -spot.width / 2, y: -spot.height / 2,
                                   width: spot.width, height: spot.height)
            let roundedPath = CGPath(roundedRect: localRect,
                                     cornerWidth: spot.cornerRadius,
                                     cornerHeight: spot.cornerRadius,
                                     transform: &transform)
            ctx.addPath(roundedPath)
            ctx.clip()
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            ctx.fill(imageRect)
            ctx.restoreGState()
        }
    }
}
