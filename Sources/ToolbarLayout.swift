import CoreGraphics

/// 工具栏的尺寸常量。
///
/// **宽度公式只有一处**（`buttonWidth`）：预计算折行、创建控件、估算组宽都用它。
/// 两边各写一份的话，改一处漏一处会让折行算在错误的位置上 ——
/// 而那种错不会报错，只是"某一行提前折了"或"最后一个按钮被挤出去"。
enum ToolbarMetrics {

    /// 单行高度。多行时工具栏总高 = 行数 × 它。
    static let rowHeight: CGFloat = 48

    /// 相邻控件之间的间距。
    static let gap: CGFloat = 2

    /// 组与组之间的竖线及其占位。
    static let separatorWidth: CGFloat = 8

    /// 第一行左侧的内边距。后续行不留 —— 折行后各行左对齐更整齐。
    static let leadingInset: CGFloat = 8

    /// 一组末尾的额外留白。
    static let groupTailGap: CGFloat = 4

    /// 工具栏顶部/底部通栏分隔线的高度。
    static let edgeSeparatorHeight: CGFloat = 1

    /// 按钮的宽度：中文标题按字数估宽，下限 36 保证两字按钮不会窄到挤。
    static func buttonWidth(_ title: String) -> CGFloat {
        max(CGFloat(title.count) * 14 + 8, 36)
    }
}

/// 把工具栏的各个「组」折成若干行。
///
/// ## 为什么需要它
///
/// 工具栏用绝对坐标排布、不换行。内容一路加到了 **1490 点宽**，而常见笔记本
/// 屏幕的可见宽度只有 **1473 点** —— 窗口比屏幕还宽，就地编辑时只能整体左移，
/// 画布就不再压在选区上：用户刚框住的位置，标注窗口偏到了一边。
///
/// ## 为什么按「组」折行，而不是按单个控件
///
/// 把一组拆到两行会让分组标签（"绘图工具""颜色"…）指不准，看上去像排错了。
/// 整组换行则每一行都由完整的组构成。
///
/// ## 为什么不用贪心
///
/// 贪心（装不下就换行）在"总宽只超一点点"时，会把**最后一个组单独挤到下一行** ——
/// 11 个组切出「第一行 10 个、第二行 1 个」，比不折还难看。
/// 这里改成：先试 1 行，不行试 2 行、3 行……每次求「各段之和的最大值最小」的切法
/// （经典线性分割），所以各行宽度尽量接近，不会出现孤零零的尾巴行。
enum ToolbarLayout {

    struct Row: Equatable {
        let range: Range<Int>
        let width: CGFloat
    }

    /// 把 `widths` 按顺序切成 `rows` 段，使各段之和的最大值最小。
    ///
    /// `rows` 超出元素个数（每段至少 1 个）时返回 nil。
    /// `best[k][i]` = 前 i 个元素分成 k 段时的最小「最大段和」。
    static func balancedRows(widths: [CGFloat], rows: Int) -> [Range<Int>]? {
        let n = widths.count
        guard rows >= 1, rows <= n else { return nil }

        var prefix = [CGFloat](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + widths[i] }

        let inf = CGFloat.greatestFiniteMagnitude
        var best = [[CGFloat]](repeating: [CGFloat](repeating: inf, count: n + 1),
                               count: rows + 1)
        var split = [[Int]](repeating: [Int](repeating: 0, count: n + 1),
                            count: rows + 1)
        best[0][0] = 0

        for k in 1...rows {
            for i in 1...n {
                // 前 k-1 段至少要占掉 k-1 个元素 —— 否则 i 个元素分不出 k 段。
                //
                // ⚠️ 这个 guard 不只是优化：`(k-1)..<i` 在 k-1 > i 时是**非法 Range**，
                // Swift 会直接 trap（"Range requires lowerBound <= upperBound"）。
                // 漏掉它的话，工具栏在窄屏上需要 3 行时就会崩 —— 离屏探针抓到的。
                guard k - 1 < i else { continue }
                for j in (k - 1)..<i {
                    guard best[k - 1][j] < inf else { continue }
                    let candidate = max(best[k - 1][j], prefix[i] - prefix[j])
                    if candidate < best[k][i] {
                        best[k][i] = candidate
                        split[k][i] = j
                    }
                }
            }
        }
        guard best[rows][n] < inf else { return nil }

        var ranges: [Range<Int>] = []
        var i = n
        for k in stride(from: rows, through: 1, by: -1) {
            let j = split[k][i]
            ranges.append(j..<i)
            i = j
        }
        return ranges.reversed()
    }

    /// 选出「行数最少、且每行都不超过 `limit`」的排布。
    ///
    /// 行数越少越好（工具栏越矮、越不挤占画布），所以从 1 行往上试。
    ///
    /// `widths` 是各组的**内容宽**（含组尾留白，**不含**组间竖线）。
    /// 一行 k 个组真实占 `sum(内容宽) + (k−1) × separatorWidth` —— 行首那个组
    /// 左边没有竖线（`ToolbarCursor.beginGroup` 就是这么画的）。竖线数依赖
    /// 「这行有几个组」，而那是分割的结果，所以不能预先摊进 `widths`。
    ///
    /// 做法：把每个组的权重 +sep 交给 `balancedRows`，段和就变成 `sum + k×sep`，
    /// 比真实值**恒多一条 sep**。每段都多同一个常数不改变「最大段和最小」的最优解，
    /// 所以均衡分割照旧，最后把那条 sep 减回来即得真实行宽。
    /// `separatorWidth = 0` 时退化为纯内容和（本函数的原始语义）。
    static func wrap(widths: [CGFloat], limit: CGFloat,
                     separatorWidth: CGFloat = 0) -> [Row] {
        guard !widths.isEmpty else { return [] }

        let weighted = widths.map { $0 + separatorWidth }

        for rows in 1...widths.count {
            guard let ranges = balancedRows(widths: weighted, rows: rows) else { continue }
            let rowWidths = ranges.map { r in
                r.reduce(CGFloat.zero) { $0 + weighted[$1] } - separatorWidth
            }
            if (rowWidths.max() ?? 0) <= limit {
                return zip(ranges, rowWidths).map { Row(range: $0, width: $1) }
            }
        }
        // 兜底：单个组就比 limit 还宽（极窄屏）。每元素一行，允许溢出。
        // 每行只有一个组 ⇒ 没有组间竖线，行宽就是内容宽本身。
        return widths.indices.map { Row(range: $0..<($0 + 1), width: widths[$0]) }
    }

    /// 给一个屏幕宽度，算出工具栏单行的宽度上限。
    ///
    /// 目标是**窗口不比屏幕宽** —— 只要窗口比屏幕宽，就地编辑就一定左移，
    /// 画布就离开了选区。留 24 点余量是避免贴着边缘时窗口阴影/圆角被裁。
    /// 这是**硬约束**；观感上的"一行别太长"由 `preferredRowWidth` 负责。
    static func widthLimit(screenVisibleWidth: CGFloat) -> CGFloat {
        max(320, screenVisibleWidth - 24)
    }

    /// 单行工具栏的**观感**宽度上限。
    ///
    /// `widthLimit` 只保证"不比屏幕宽"，可屏幕有 2000 点时一行就能排到 1500+ ——
    /// 变成一条又长又密的横带：分组标签挤在一起、找工具要横扫整个屏幕，
    /// 而且窗口宽度会被工具栏撑到 1500 以上（哪怕截图只有 200 点宽）。
    /// 超过这个宽度就交给 `wrap` 折行 —— 它做的是均衡分割，
    /// 两行宽度接近，不会出现"第一行塞满、第二行孤零零一个组"。
    ///
    /// 900 这个数：12 个组总宽约 1570，折两行后每行约 790–840，
    /// 既能一眼扫完，也不至于矮到一行只放两三个组。
    static let preferredRowWidth: CGFloat = 900

    /// 排版时**真正**使用的单行上限 = 屏幕硬约束与观感上限取小。
    static func effectiveLimit(screenVisibleWidth: CGFloat) -> CGFloat {
        min(widthLimit(screenVisibleWidth: screenVisibleWidth), preferredRowWidth)
    }
}

/// 工具栏排版游标：按预先算好的折行方案，给出每个控件的坐标。
///
/// 用法固定 —— 每进入一个组先 `beginGroup()`，然后按顺序把该组的控件
/// `place(width:gapAfter:)` 过去，组结束时 `endGroup()`。
/// **顺序必须与构造时传入的 `groupWidths` 一致**，错位会让折行落在错误的组上。
///
/// `groupWidths` 是各组的**内容宽**（含组尾留白，不含组间竖线）——
/// 竖线由 `beginGroup` 按「是不是行首」决定，摊进预算就会把行首组多算一条。
/// 生产侧的预算由 `AnnotationWindow.measureToolbarGroupWidths` 干跑同一份
/// 排布代码得出，所以两者偏差恒为 0（`toolbar_budget_probe` 钉住这条）。
final class ToolbarCursor {

    let rowCount: Int
    let rowHeight: CGFloat

    /// 工具栏总高度（单行时就是 rowHeight）。
    var totalHeight: CGFloat { CGFloat(rowCount) * rowHeight }

    /// 工具栏真正需要的宽度 = 各行最右端的最大值。
    /// 窗口宽度据此决定，所以它**不是**估算值，而是逐个控件累加出来的实际值。
    var contentWidth: CGFloat { rowRights.max() ?? 0 }

    /// 各行实际排到的最右端。与 `contentWidth` 同源，只是不取最大值 ——
    /// 探针用它逐行核对「折行方案的预测 == 真实排布」。
    var rowWidths: [CGFloat] { rowRights }

    /// 走查过程中逐组量到的**内容宽**（含组尾留白，不含组间竖线）。
    /// 这就是折行预算的唯一来源：干跑一遍排布即可，不需要第二份宽度公式。
    var groupContentWidths: [CGFloat] { measuredGroupWidths }

    /// 当前游标位置。用于放分组标签 —— 标签要与它所属组的第一个控件左对齐。
    var currentX: CGFloat { x }

    /// 当前游标所在行（0 在最上方）。多行时用于把控件放到正确的行上。
    var currentRowIndex: Int { currentRow }

    private let rowOfGroup: [Int]
    private var rowRights: [CGFloat]
    private var measuredGroupWidths: [CGFloat] = []
    private var groupStartX: CGFloat = 0
    private var groupIndex = -1
    private var currentRow = 0
    private var x: CGFloat = ToolbarMetrics.leadingInset
    private var isFirstInRow = true

    init(groupWidths: [CGFloat], limit: CGFloat,
         rowHeight: CGFloat = ToolbarMetrics.rowHeight) {
        let rows = ToolbarLayout.wrap(widths: groupWidths, limit: limit,
                                      separatorWidth: ToolbarMetrics.separatorWidth)
        self.rowCount = max(rows.count, 1)
        self.rowHeight = rowHeight

        var map = [Int](repeating: 0, count: groupWidths.count)
        for (r, row) in rows.enumerated() {
            for i in row.range where i < map.count { map[i] = r }
        }
        self.rowOfGroup = map
        self.rowRights = [CGFloat](repeating: 0, count: max(rows.count, 1))
    }

    /// 干跑用的游标：不预设折行方案，所有组都落在第 0 行，只用来量各组内容宽。
    ///
    /// 组内容宽与它排在第几行**无关**（`place` 的增量不依赖行），所以这样量出来的
    /// 值对任何折行方案都成立 —— 于是「先量再折」不会陷入「折行需要宽度、宽度需要
    /// 折行」的循环。空 `groupWidths` 时 `rowOfGroup` 为空，`beginGroup` 回落到
    /// 最后一行（这里就是第 0 行），正是想要的行为。
    static func measuring() -> ToolbarCursor {
        ToolbarCursor(groupWidths: [], limit: .greatestFiniteMagnitude)
    }

    /// 进入下一个组。
    ///
    /// 返回该组所在行的起始 y（AppKit 坐标，**行 0 在最上方** —— 内容从上往下读），
    /// 以及组间竖线的 x（本组是所在行的第一个组时为 nil，行首不画竖线）。
    @discardableResult
    func beginGroup() -> (baseY: CGFloat, separatorX: CGFloat?) {
        groupIndex += 1
        let row = rowOfGroup.indices.contains(groupIndex) ? rowOfGroup[groupIndex] : rowCount - 1

        if row != currentRow {
            currentRow = row
            x = 0                     // 后续行不留左侧内边距，与画布左对齐
            isFirstInRow = true
        }

        var separatorX: CGFloat?
        if !isFirstInRow {
            x += ToolbarMetrics.separatorWidth
            separatorX = x - ToolbarMetrics.separatorWidth / 2
        }
        isFirstInRow = false
        // 竖线**之后**才起算：组内容宽不含组间竖线，否则行首组会被多算一条。
        groupStartX = x

        return (CGFloat(rowCount - 1 - row) * rowHeight, separatorX)
    }

    /// 放一个控件，返回它的 x。
    func place(width: CGFloat, gapAfter: CGFloat = ToolbarMetrics.gap) -> CGFloat {
        let at = x
        x += width + gapAfter
        rowRights[currentRow] = max(rowRights[currentRow], x)
        return at
    }

    /// 一组结束时调用，推进组尾留白。
    func endGroup() {
        x += ToolbarMetrics.groupTailGap
        rowRights[currentRow] = max(rowRights[currentRow], x)
        measuredGroupWidths.append(x - groupStartX)
    }
}
