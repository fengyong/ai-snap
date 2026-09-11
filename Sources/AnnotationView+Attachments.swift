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
    ///
    /// 矩形类形状（矩形 / 贴纸 / 文字）统一走 `RectPerimeter.parameter` ——
    /// 它与各形状自己的 `pointOnPerimeter` 共用同一套分段，两者天然互逆。
    /// 圆是角度参数化，单独一支。
    ///
    /// （这一段原先三个形状各写一份几乎相同的分段判定，改动任何一处都得记得
    /// 同步另外两处，而且不一致时症状只是"箭头偶尔吸到奇怪的位置"，很难查。）
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
            return RectPerimeter.parameter(for: point, center: rect.center,
                                           size: CGSize(width: rect.width, height: rect.height),
                                           rotation: rect.rotation)
        }
        if let stamp = obj as? StampObject {
            return RectPerimeter.parameter(for: point, center: stamp.center,
                                           size: CGSize(width: stamp.size, height: stamp.size),
                                           rotation: stamp.rotation)
        }
        if let text = obj as? TextShape {
            return RectPerimeter.parameter(for: point, center: text.center,
                                           size: text.contentSize,
                                           rotation: text.rotation)
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
            if let text = parent as? TextShape {
                return text.pointOnPerimeter(at: parameter)
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

    // 级联删除（删除对象时一并删掉挂在它上面的箭头）的实现在
    // `AnnotationView.takeOutOfCanvas(_:)`，不在本文件。
    //
    // 之所以放在画布上：它还负责「把摘下来的东西交回给调用方去记撤销」，而删除键 /
    // 选中框叉号 / 橡皮擦三条路对撤销的粒度要求不同（一个是「一次删一个」、
    // 一个是「整笔拖拽合成一步」）。放在画布上三条路才能共用同一份级联规则，
    // 不必三处各写一遍 —— 漏掉一处就是画布上留下一个吊在不存在父对象上的箭头。
}
