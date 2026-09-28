import Cocoa

// MARK: - Rendering

/// 画布的绘制细节：选中态手柄、拖拽预览。
///
/// **注意 `draw(_:)` 本身没有放在这里** —— 它是 `NSView` 的 override，
/// 而 Swift **不允许在 extension 里写 override**（会报 "Overriding declarations
/// are not allowed in extensions"）。所以 `draw(_:)` 留在 `AnnotationView` 类体内
/// 作为渲染入口，本文件放它调用的绘制细节。
extension AnnotationView {

    /// 在附着锚点画一个小环。
    ///
    /// 两个场景共用：拖拽箭头时的**落笔前预览**（"松手会挂在这里"）与选中箭头后的
    /// **事后可查**。两处各画一份的话，改了一处另一处就不一致了。
    func drawAttachRing(at point: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [])
        let r: CGFloat = 5
        let ring = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
        ctx.fillEllipse(in: ring)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: ring)
        ctx.restoreGState()
    }

    /// 选中态：发光虚线框 + 四角手柄 + 右上角删除按钮
    func drawSelectionHandles(for obj: any AnnotationObject, in ctx: CGContext) {
        let box = obj.boundingBox
        let padding: CGFloat = 4

        // 1. 发光选中框（蓝色阴影 + 虚线边框）
        ctx.saveGState()
        let selRect = box.insetBy(dx: -padding, dy: -padding)
        ctx.setShadow(offset: .zero, blur: 8,
                      color: NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        let selPath = CGPath(roundedRect: selRect, cornerWidth: 3, cornerHeight: 3,
                             transform: nil)
        ctx.addPath(selPath)
        ctx.strokePath()
        ctx.restoreGState()

        // 2. 四角手柄点
        let handleSize: CGFloat = 6
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [])

        for point in obj.selectionHandlePoints() {
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            ctx.fillEllipse(in: handleRect)
            ctx.strokeEllipse(in: handleRect)
        }

        // 2.5 附着的端点：画一个小环（**事后可查**）
        //
        // 没有它的话，"这一端挂在了别的形状上"在界面上毫无迹象 —— 用户只能等到
        // 移动父对象时发现箭头跟着动了才知道；而删掉父对象时箭头又被一起删掉，
        // 那时更摸不着头脑（"我只是删了个矩形，箭头怎么也没了"）。
        //
        // 落笔**之前**的提示在 `draw(_:)` 的第 4.5 步（拖拽预览），两者共用这里的画法。
        if let arrow = obj as? Arrow {
            for attachment in [arrow.startAttachment, arrow.endAttachment] {
                guard let attachment = attachment,
                      let anchor = resolveAttachmentPosition(attachment) else { continue }
                drawAttachRing(at: anchor, in: ctx)
            }
        }

        // 3. 右上角删除叉号按钮
        let deleteSize: CGFloat = 16
        let deleteCenter = AnnotationView.deleteButtonCenter(for: selRect,
                                                            deleteSize: deleteSize)
        // 红色圆底
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
        let deleteRect = CGRect(x: deleteCenter.x - deleteSize / 2,
                                y: deleteCenter.y - deleteSize / 2,
                                width: deleteSize, height: deleteSize)
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fillEllipse(in: deleteRect)
        ctx.restoreGState()

        // 白色叉号
        let crossSize: CGFloat = 4
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: deleteCenter.x - crossSize, y: deleteCenter.y - crossSize))
        ctx.addLine(to: CGPoint(x: deleteCenter.x + crossSize, y: deleteCenter.y + crossSize))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: deleteCenter.x - crossSize, y: deleteCenter.y + crossSize))
        ctx.addLine(to: CGPoint(x: deleteCenter.x + crossSize, y: deleteCenter.y - crossSize))
        ctx.strokePath()
    }

    /// 拖拽过程中的预览。具体画法交给工具自己的 handler。
    func drawPreview(tool: DrawingTool, start: CGPoint, end: CGPoint, in ctx: CGContext) {
        ToolRegistry.handler(for: tool)?
            .drawPreview(from: start, to: end, tool: tool, in: ctx,
                         context: toolContext(colorKey: 0))
    }
}
