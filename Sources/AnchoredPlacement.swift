import CoreGraphics

/// 就地编辑时，标注窗口该落在哪里、工具栏该挂在画布的哪一侧。
///
/// **刻意抽成不依赖 AppKit 的纯函数**：这几条边界（选区贴屏幕底边 / 顶边 / 右边、
/// 窗口比屏幕还宽）都只在特定屏幕上才复现，而离屏探针进程里 `NSScreen.main` 是 nil，
/// 根本走不到这些分支。抽出来就能对着一张假想的屏幕把每种情况都算一遍。
///
/// ## 为什么需要它
///
/// 窗口的原点是「画布左下角钉在选区左下角、工具栏挂在画布下方」——
/// 于是 `origin.y = 选区底边 − 工具栏高度`。选区一旦贴着屏幕最底部，
/// 这个值就是负的，**整条工具栏沉到屏幕外**：保存 / 复制 / 贴图这些按钮点不到。
/// 键盘 Enter 仍能复制并关闭，但用户不知道还有这条路 —— 等同于"保存按钮消失了"。
enum AnchoredPlacement {

    struct Result: Equatable {
        /// 窗口左下角（屏幕坐标，AppKit 左下原点）
        let origin: CGPoint
        /// 工具栏是否挂在画布**上方**
        let toolbarAtTop: Bool
    }

    /// 计算落点。
    ///
    /// 优先顺序（前一个放不下才退到下一个）：
    /// 1. 工具栏在画布下方 —— 常规情况
    /// 2. 工具栏翻到画布上方 —— 画布**仍然压在选区上**，只是工具栏换了一侧
    /// 3. 夹进屏幕内，放弃对齐 —— 屏幕实在装不下（超大选区 / 极小屏）
    ///
    /// 边界用 `screenFrame`（屏幕物理范围）而不是 `visibleFrame`：
    /// 硬要求是"不能出屏"，而工具栏压住 Dock 是可以接受的（Dock 会自己让开）。
    /// 若用 visibleFrame 做边界，选区包含 Dock 区域时窗口会被无谓地推上去。
    static func compute(anchor: CGRect,
                        windowSize: CGSize,
                        toolbarHeight: CGFloat,
                        screenFrame: CGRect) -> Result {
        guard screenFrame.width > 0, screenFrame.height > 0,
              windowSize.width > 0, windowSize.height > 0 else {
            return Result(origin: CGPoint(x: anchor.minX, y: anchor.minY - toolbarHeight),
                          toolbarAtTop: false)
        }

        // 水平：左对齐选区，超出右边界时左移（此前已实现的行为，保持）
        let maxX = screenFrame.maxX - windowSize.width
        let x = min(max(anchor.minX, screenFrame.minX), max(screenFrame.minX, maxX))

        // 垂直：候选 1 —— 工具栏在下
        let belowY = anchor.minY - toolbarHeight
        let lowestY = screenFrame.minY
        let highestY = screenFrame.maxY - windowSize.height

        if belowY >= lowestY && belowY <= highestY {
            return Result(origin: CGPoint(x: x, y: belowY), toolbarAtTop: false)
        }

        // 候选 2 —— 工具栏翻到画布上方。画布底边就是选区底边，所以 y 取 anchor.minY。
        let aboveY = anchor.minY
        if aboveY >= lowestY && aboveY <= highestY {
            return Result(origin: CGPoint(x: x, y: aboveY), toolbarAtTop: true)
        }

        // 候选 3 —— 都放不下：夹进屏幕，放弃"画布压在选区上"
        let clamped = min(max(belowY, lowestY), max(lowestY, highestY))
        return Result(origin: CGPoint(x: x, y: clamped), toolbarAtTop: false)
    }
}
