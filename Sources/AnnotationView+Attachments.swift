import Cocoa

/// 附着判定阈值（点）：距离小于它的 snap point / 周长点才认为「要吸附上」。
///
/// 放在文件级常量而不是类里：`extension` 不能添加实例存储属性，
/// 而这个值只被本文件的附着逻辑使用。
private let attachThreshold: CGFloat = 15.0

// MARK: - Object Attachment

/// 箭头与形状之间的附着。
///
/// 箭头的两个端点可以「粘」在某个形状的吸附点或周长上，之后形状被移动/旋转/缩放时，
/// 箭头端点跟着走 —— 这是矢量标注相对栅格化标注的一个主要体验优势。
///
/// 拆到独立文件是因为它与画布的其它职责（绘制、命中、撤销）没有耦合：
/// 只依赖对象表 `objects`，输入一个点、输出一个 `Attachment`。
extension AnnotationView {

    /// 检测一个点附近是否有可附着的形状，返回 Attachment 或 nil
    func detectAttachment(at point: CGPoint, excludeKey: UInt32?) -> Attachment? {
        var bestDist: CGFloat = attachThreshold
        var bestAttachment: Attachment?

        for (key, obj) in objects {
            if key == excludeKey { continue }
            // 箭头不作为父对象（避免箭头套箭头这种无意义的结构）
            if obj is Arrow { continue }

            // 先检查 snap points
            for (index, snap) in obj.snapPoints().enumerated() {
                let dist = hypot(point.x - snap.point.x, point.y - snap.point.y)
                if dist < bestDist {
                    bestDist = dist
                    bestAttachment = Attachment(parentKey: key, anchorType: .snapPoint(index: index))
                }
            }

            // 检查周长最近点
            let nearest = obj.nearestPerimeterPoint(to: point)
            let dist = hypot(point.x - nearest.x, point.y - nearest.y)
            if dist < bestDist {
                bestDist = dist
                // 计算周长参数
                let param = computePerimeterParameter(for: obj, at: nearest)
                bestAttachment = Attachment(parentKey: key, anchorType: .perimeter(parameter: param))
            }
        }
        return bestAttachment
    }

    /// 计算点在对象周长上的参数 (0...1)
    private func computePerimeterParameter(for obj: any AnnotationObject,
                                           at point: CGPoint) -> CGFloat {
        if let circle = obj as? CircleShape {
            let local = rotatePoint(point, around: circle.center, by: -circle.rotation)
            let dx = local.x - circle.center.x
            let dy = local.y - circle.center.y
            var angle = atan2(dy / circle.radiusY, dx / circle.radiusX)
            if angle < 0 { angle += 2 * .pi }
            return angle / (2 * .pi)
        }
        if let rect = obj as? RectangleShape {
            // 转换到局部坐标
            let local = rotatePoint(point, around: rect.center, by: -rect.rotation)
            let lx = local.x - rect.center.x
            let ly = local.y - rect.center.y
            let hw = rect.width / 2, hh = rect.height / 2
            let perimeter = 2 * (rect.width + rect.height)
            // 沿周长测量距离
            var d: CGFloat = 0
            if ly <= -hh + 0.1 { d = lx + hw }                                  // bottom
            else if lx >= hw - 0.1 { d = rect.width + (ly + hh) }               // right
            else if ly >= hh - 0.1 { d = rect.width + rect.height + (hw - lx) } // top
            else { d = 2 * rect.width + rect.height + (hh - ly) }               // left
            return max(0, min(1, d / perimeter))
        }
        if let stamp = obj as? StampObject {
            let local = rotatePoint(point, around: stamp.center, by: -stamp.rotation)
            let lx = local.x - stamp.center.x
            let ly = local.y - stamp.center.y
            let half = stamp.size / 2
            let perimeter = stamp.size * 4
            var d: CGFloat = 0
            if ly <= -half + 0.1 { d = lx + half }
            else if lx >= half - 0.1 { d = stamp.size + (ly + half) }
            else if ly >= half - 0.1 { d = 2 * stamp.size + (half - lx) }
            else { d = 3 * stamp.size + (half - ly) }
            return max(0, min(1, d / perimeter))
        }
        return 0
    }

    /// 解析附着点的当前世界坐标
    func resolveAttachmentPosition(_ attachment: Attachment) -> CGPoint? {
        guard let parent = objects[attachment.parentKey] else { return nil }

        switch attachment.anchorType {
        case .snapPoint(let index):
            let snaps = parent.snapPoints()
            guard index < snaps.count else { return nil }
            return snaps[index].point

        case .perimeter(let parameter):
            if let circle = parent as? CircleShape {
                return circle.pointOnPerimeter(at: parameter)
            }
            if let rect = parent as? RectangleShape {
                return rect.pointOnPerimeter(at: parameter)
            }
            if let stamp = parent as? StampObject {
                return stamp.pointOnPerimeter(at: parameter)
            }
            return nil
        }
    }

    /// 更新所有附着到指定父对象的箭头端点
    ///
    /// 父对象被移动/旋转/缩放之后必须调用，否则箭头端点会停在原地、与形状脱节。
    func updateAttachedArrows(forParent parentKey: UInt32) {
        for (_, obj) in objects {
            guard let arrow = obj as? Arrow else { continue }
            if let att = arrow.startAttachment, att.parentKey == parentKey {
                if let pos = resolveAttachmentPosition(att) {
                    arrow.startPoint = pos
                }
            }
            if let att = arrow.endAttachment, att.parentKey == parentKey {
                if let pos = resolveAttachmentPosition(att) {
                    arrow.endPoint = pos
                }
            }
        }
    }

    /// 级联删除：删除所有附着到指定父对象的箭头
    ///
    /// 父对象没了，附着在它上面的箭头就成了指向虚空的悬空引用，必须一起删。
    func cascadeDelete(parentKey: UInt32) {
        var toDelete: [UInt32] = []
        for (key, obj) in objects {
            guard let arrow = obj as? Arrow else { continue }
            if (arrow.startAttachment?.parentKey == parentKey) ||
               (arrow.endAttachment?.parentKey == parentKey) {
                toDelete.append(key)
            }
        }
        for key in toDelete {
            objects.removeValue(forKey: key)
            zOrder.removeAll { $0 == key }
        }
    }
}
