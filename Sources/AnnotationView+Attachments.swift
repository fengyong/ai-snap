import Cocoa

/// 附着判定阈值（点）：距离小于它的 snap point / 周长点才认为「要吸附上」。
///
/// 放在文件级常量而不是类里：`extension` 不能添加实例存储属性，
/// 而这个值只被本文件的附着逻辑使用。
/// 检测附着的判定半径（点）：箭头端点落在这个范围内就记住附着关系。
///
/// 比 `AnnotationView.snapThreshold`（12，被动吸附的**提示**半径）大一点是有意的：
/// 提示宁可少亮，决定宁可多记 —— 详见那边的注释。
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
                // 计算周长参数。
                //
                // 这里**必须**用协议方法：原来是一个只认四种类型的 switch，遇到
                // Redaction / Spotlight / StepBadge 会返回 0，于是"能挂上、但解析不回来" ——
                // 表现是父对象移动时箭头不跟，父对象删除时箭头却被级联删掉。
                // 现在每个类型都自己实现（协议里没有默认实现，新类型不表态就编译不过）。
                let param = obj.perimeterParameter(for: nearest)
                bestAttachment = Attachment(parentKey: key, anchorType: .perimeter(parameter: param))
            }
        }
        return bestAttachment
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
            // 同样走协议：任何能当父对象的类型都必须能把自己的参数换回坐标
            return parent.pointOnPerimeter(at: parameter)
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
