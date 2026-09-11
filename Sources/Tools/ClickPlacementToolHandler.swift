import Cocoa

/// 单击放置类工具：序号与贴纸。
///
/// 它们不需要拖拽（点一下就地放一个），所以只实现 `placeObject`。
/// 放在同一个 handler 里是因为两者的「放置」逻辑完全一致 ——
/// 造对象、交回画布登记，差别只在造什么。
struct ClickPlacementToolHandler: AnnotationToolHandler {

    /// 贴纸的固定尺寸。抽成常量是因为预览、命中区都隐含依赖它。
    static let stampSize: CGFloat = 48

    func handles(_ tool: DrawingTool) -> Bool {
        switch tool {
        case .step, .stamp:
            return true
        default:
            return false
        }
    }

    func placeObject(at point: CGPoint, tool: DrawingTool,
                     context: ToolContext) -> (any AnnotationObject)? {
        switch tool {
        case .step:
            return StepBadge(center: point,
                             number: context.nextStepNumber(),
                             color: context.color,
                             hitTestColorKey: context.colorKey)
        case .stamp(let stampType):
            return StampObject(center: point,
                               size: Self.stampSize,
                               stampType: stampType,
                               color: context.color,
                               hitTestColorKey: context.colorKey)
        default:
            return nil
        }
    }
}
