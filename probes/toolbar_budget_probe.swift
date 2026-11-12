import Cocoa

// 工具栏折行预算探针（O4，2026-11-12）。
//
// 背景：折行方案的**输入**（各组宽度预算）与折行方案的**执行**（创建控件、逐个
// place）以前是两份独立代码 —— `toolbarGroupWidths` 手写 12 个宽度表达式，
// `createToolbar` 里另写一遍 `place(width:gapAfter:)`。两边靠人对齐，而旧注释
// 把偏差说成"一两像素出入，后果只是某行提前或延后收一个组"，正好劝退了后来修它的人。
//
// 实测偏差远不止一两像素：9 个组的预算漏加了组尾留白（各 4pt），行首组又被多算
// 一条竖线（8pt）。O4 把预算改成**排布代码本身的干跑**，偏差在结构上恒为 0。
//
// 这份探针钉住的就是那个"恒为 0"，以及它依赖的两条记账规则：
//   规则 1：组内容宽 = 各控件(宽 + 后间距)之和 + 组尾留白，**不含**组间竖线。
//   规则 2：一行 k 个组真实占 sum(内容宽) + (k−1) × 竖线宽 —— 行首左边没有竖线。
//
// 为什么这些断言不是同义反复：
//   · §2 用的是**手推的字面值**（从按钮标题字数、控件宽度算出来），不是读实现；
//   · §4 比的是两套**不同算法**：wrap 的前缀和分割 vs 游标的逐控件增量累加；
//   · §5 比的是**真实 AppKit 控件的 frame**，不是游标自己的记账。
//
//      run_probe toolbar_budget_probe "${ALL_SOURCES[@]}"

setbuf(stdout, nil)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
    else { fail += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
}

func makeImage(_ w: Int, _ h: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor.gray.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    img.unlockFocus()
    return img
}

let sep = ToolbarMetrics.separatorWidth
let tail = ToolbarMetrics.groupTailGap
let inset = ToolbarMetrics.leadingInset
let rowHeight = ToolbarMetrics.rowHeight

// 生产侧的调色板色块数 —— 预算必须跟着它变，不能写死。
let paletteCount = ColorPalette.allPalettes[Preferences.shared.paletteIndex].colors.count

print("=== 1. 纯函数：一行 k 个组只占 (k−1) 条竖线 ===\n")
do {
    // 三个 100 的组，上限 208。
    // 记竖线：两行切成 [100] / [100,100] → 行宽 100 / 208，刚好卡住上限。
    // 不记竖线（sep=0）：同样两行 → 行宽 100 / 200。
    // 两者差的就是那条竖线 —— 这条断言把「竖线记账」与「不记账」区分开。
    let withSep = ToolbarLayout.wrap(widths: [100, 100, 100], limit: 208, separatorWidth: sep)
    check("记竖线：折 2 行", withSep.count == 2, "\(withSep.count)")
    check("记竖线：行宽 = 100 / 208（第二行含 1 条竖线）",
          withSep.map(\.width) == [100, 208],
          withSep.map { "\(Int($0.width))" }.joined(separator: " / "))

    let noSep = ToolbarLayout.wrap(widths: [100, 100, 100], limit: 208)
    check("不记竖线（默认参数）：行宽 = 100 / 200",
          noSep.map(\.width) == [100, 200],
          noSep.map { "\(Int($0.width))" }.joined(separator: " / "))

    // ★ 上限再紧一点，竖线记账就会**改变切法** —— 这条把「记了」与「没记」
    // 真正区分开（上面 208 那档两者恰好都切 2 行，区分不出来）。
    // 记竖线：两行最好是 100 / 208，208 > 200 装不下 → 只能 3 行。
    // 不记竖线：两行 100 / 200 刚好卡住 → 2 行。
    let tightWith = ToolbarLayout.wrap(widths: [100, 100, 100], limit: 200, separatorWidth: sep)
    let tightWithout = ToolbarLayout.wrap(widths: [100, 100, 100], limit: 200)
    check("★ 上限 200：记竖线 → 3 行", tightWith.count == 3, "\(tightWith.count)")
    check("★ 上限 200：不记竖线 → 2 行（切法确实不同）",
          tightWithout.count == 2, "\(tightWithout.count)")

    // 一行装得下时：k 个组 = sum + (k−1)×sep
    for k in 1...4 {
        let w = [CGFloat](repeating: 100, count: k)
        let rows = ToolbarLayout.wrap(widths: w, limit: 10000, separatorWidth: sep)
        let expected = CGFloat(k) * 100 + CGFloat(k - 1) * sep
        check("\(k) 个组排一行 → 宽 \(Int(expected))（含 \(k - 1) 条竖线）",
              rows.count == 1 && rows[0].width == expected,
              rows.map { "\(Int($0.width))" }.joined(separator: " / "))
    }

    // 兜底路径：单个组就比上限宽 → 每元素一行，此时**没有**组间竖线
    let overflow = ToolbarLayout.wrap(widths: [100, 100], limit: 50, separatorWidth: sep)
    check("极窄屏兜底：每元素一行，行宽就是内容宽（不加竖线）",
          overflow.count == 2 && overflow.map(\.width) == [100, 100],
          overflow.map { "\(Int($0.width))" }.joined(separator: " / "))

    // 均衡分割不能被竖线记账破坏：每段都多同一条 sep，最优解不变
    let balanced = ToolbarLayout.wrap(widths: [100, 100, 100, 100], limit: 250,
                                      separatorWidth: sep)
    check("均衡仍然成立：4 个组切 2 行，各 2 个（不是 3+1）",
          balanced.count == 2 && balanced.allSatisfy { $0.range.count == 2 },
          balanced.map { "\($0.range.count)" }.joined(separator: " / "))
}

print("\n=== 2. 预算的字面值（手推，不读实现）===\n")
do {
    // 内容宽 = Σ(控件宽 + 后间距) + 组尾留白。按钮宽 = max(字数×14+8, 36)。
    // 这些数是**从 UI 规格手推**的：改了控件宽度就必须回来改这里，
    // 而不是像旧预算那样在另一份代码里悄悄漂移。
    let expected: [(String, CGFloat)] = [
        ("箭头样式：下拉 84 + 后距 4 + 尾距 4", 92),
        ("编辑：撤销 36+2、重做 36+2、尾距 4", 80),
        ("线宽：槽位 104 + 后距 4 + 尾距 4", 112),
        ("线型：下拉 76 + 后距 4 + 尾距 4", 84),
        ("贴纸：下拉 56 + 后距 6 + 尾距 4", 66),
        ("水印：勾选 48+2、文本框 72+6、尾距 4", 132),
        ("导出：保存/复制/贴图 各 36+2、尾距 4", 118),
        ("识别：OCR 50（3 字）+ 后距 6 + 尾距 4", 60),
        ("帮助：36 + 后距 0 + 尾距 4", 40),
        ("放弃：36 + 后距 0 + 尾距 4", 40),
    ]
    let measured = AnnotationWindow.measureToolbarGroupWidths(paletteColorCount: paletteCount)
    check("预算共 12 组", measured.count == 12, "\(measured.count)")

    // 组序：0 绘图 / 1 箭头样式 / 2 编辑 / 3 颜色 / 4 线宽 / 5 线型 /
    //       6 贴纸 / 7 水印 / 8 导出 / 9 识别 / 10 帮助 / 11 放弃
    let index = [1, 2, 4, 5, 6, 7, 8, 9, 10, 11]
    for (i, item) in expected.enumerated() {
        check(item.0, measured[index[i]] == item.1,
              "\(Int(measured[index[i]])) vs \(Int(item.1))")
    }

    // 绘图工具组：15 个工具，14 个两字（36）+「马赛克」三字（50），各后距 2，尾距 4
    let toolGroup = CGFloat(14 * 36 + 50) + CGFloat(15 * 2) + tail
    check("绘图工具：15 个按钮 554 + 后距 30 + 尾距 4 = \(Int(toolGroup))",
          measured[0] == toolGroup, "\(Int(measured[0]))")

    // 颜色组：换色 36+4、色块 n×30+4、尾距 4
    let colorGroup: CGFloat = 36 + 4 + CGFloat(paletteCount) * 30 + 4 + tail
    check("颜色：换色 40 + 色块 \(paletteCount)×30+4 + 尾距 4 = \(Int(colorGroup))",
          measured[3] == colorGroup, "\(Int(measured[3]))")

    // ★ 旧预算漏加的正是这个尾距。逐组确认它**在**预算里：
    // 去掉尾距后应当正好等于「各控件占位之和」——用帮助组（后距 0）最干净。
    check("帮助组预算含组尾留白（旧预算漏的就是这一项）",
          measured[10] == ToolbarMetrics.buttonWidth("帮助") + tail,
          "\(Int(measured[10]))")
}

print("\n=== 3. 预算 == 真实排布（干跑 vs 实跑，逐组偏差 0）===\n")
do {
    let budget = AnnotationWindow.measureToolbarGroupWidths(paletteColorCount: paletteCount)
    // 实跑：用预算构造真实折行方案的游标，再走同一份排布代码。
    let limit = ToolbarLayout.effectiveLimit(screenVisibleWidth: 1440)
    let cursor = ToolbarCursor(groupWidths: budget, limit: limit)
    let layouts = AnnotationWindow.layoutToolbarGroups(cursor, paletteColorCount: paletteCount)
    let actual = cursor.groupContentWidths

    check("实跑也量到 12 组", actual.count == 12, "\(actual.count)")
    var maxDeviation: CGFloat = 0
    for i in 0..<min(budget.count, actual.count) {
        maxDeviation = max(maxDeviation, abs(budget[i] - actual[i]))
    }
    check("★ 逐组偏差恒为 0（预算就是排布的干跑）", maxDeviation == 0,
          "最大偏差 \(maxDeviation)")
    check("折行方案非平凡（确实折了行，否则这条核对没意义）",
          cursor.rowCount >= 2, "\(cursor.rowCount) 行")
    check("每组都产出至少一个控件坐标", layouts.allSatisfy { !$0.xs.isEmpty })
    check("控件坐标总数 = 31（15 工具 + 16 个其它控件）",
          layouts.reduce(0) { $0 + $1.xs.count } == 31,
          "\(layouts.reduce(0) { $0 + $1.xs.count })")
}

print("\n=== 4. 折行预测 == 游标实际行宽（两套不同算法）===\n")
do {
    // wrap 用前缀和 + 线性分割算行宽；游标用逐控件增量累加。
    // 两者必须逐行相等 —— 组尾留白 / 竖线 / 左侧内边距任何一处记账不一致都会红。
    //
    // ⚠️ 屏宽必须覆盖**硬约束真正起作用**的档位：preferredRowWidth = 900 会把
    // 宽屏的上限一律压到 900，只测 2560/1440/1280 等于把同一个上限测三遍。
    // 变异测试实测过：只用宽屏时「游标忘了传竖线宽」这个回归**抓不到**
    // （切法恰好没变），必须加上 900/800/600/400 这几档窄屏。
    for screenWidth in [2560.0, 1440.0, 1280.0, 1024.0, 900.0, 800.0, 600.0, 400.0] {
        let budget = AnnotationWindow.measureToolbarGroupWidths(paletteColorCount: paletteCount)
        let limit = ToolbarLayout.effectiveLimit(screenVisibleWidth: screenWidth)
        let predicted = ToolbarLayout.wrap(widths: budget, limit: limit, separatorWidth: sep)
        let cursor = ToolbarCursor(groupWidths: budget, limit: limit)
        _ = AnnotationWindow.layoutToolbarGroups(cursor, paletteColorCount: paletteCount)

        check("屏宽 \(Int(screenWidth))（上限 \(Int(limit))）：行数一致",
              cursor.rowCount == predicted.count,
              "\(cursor.rowCount) vs \(predicted.count)")

        var worst: CGFloat = 0
        var overLimit = 0
        for (r, row) in predicted.enumerated() where r < cursor.rowWidths.count {
            // 第 0 行留左侧内边距，后续行不留（与画布左对齐）——
            // 这条规则在游标里，wrap 不知道它，所以核对时要补上。
            let lead = (r == 0 ? inset : 0)
            let expected = row.width + lead
            worst = max(worst, abs(cursor.rowWidths[r] - expected))
            // 真实排布出来的行宽必须装得下 —— 单组就比上限宽的兜底行除外。
            // 这一条查的是**实际值**，不是预测值：预算少算竖线时，
            // 预测仍然"看起来装得下"，只有实际值会露馅。
            if row.range.count > 1 && cursor.rowWidths[r] - lead > limit + 0.5 {
                overLimit += 1
            }
        }
        check("屏宽 \(Int(screenWidth))：★ 逐行偏差 0（含左侧内边距规则）",
              worst == 0, "最大偏差 \(worst)")
        check("屏宽 \(Int(screenWidth))：★ 实际行宽都不超限（多组行）",
              overLimit == 0, "超限 \(overLimit) 行")
    }
}

print("\n=== 5. 真实窗口：每个控件都落在走查给出的 x 上 ===\n")
do {
    // 用小图让窗口宽度完全由工具栏决定。
    let window = AnnotationWindow(image: makeImage(120, 90))
    guard let container = window.contentView,
          let toolbar = container.subviews.first(where: { v in
              v.subviews.contains { $0 is NSButton }
          }) else { print("❌ 找不到工具栏"); exit(1) }

    let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let limit = ToolbarLayout.effectiveLimit(screenVisibleWidth: screen.width)
    let budget = AnnotationWindow.measureToolbarGroupWidths(paletteColorCount: paletteCount)
    let cursor = ToolbarCursor(groupWidths: budget, limit: limit)
    let layouts = AnnotationWindow.layoutToolbarGroups(cursor, paletteColorCount: paletteCount)

    check("真实工具栏行数 == 走查行数",
          Int((toolbar.frame.height / rowHeight).rounded()) == cursor.rowCount,
          "\(Int((toolbar.frame.height / rowHeight).rounded())) vs \(cursor.rowCount)")

    // 分组标签高 10；竖线是 NSBox。其余都是控件。
    func isGroupLabel(_ v: NSView) -> Bool { v is NSTextField && abs(v.frame.height - 10) < 0.5 }
    let controls = toolbar.subviews.filter { !($0 is NSBox) && !isGroupLabel($0) }

    func rowOf(_ v: NSView) -> Int {
        Int(((toolbar.frame.height - v.frame.maxY) / rowHeight).rounded(.down))
    }
    // 走查侧：组所在行 = rowCount−1 − baseY/rowHeight
    var expectedSlots: [String: Int] = [:]   // "行:x" → 该坐标应被几个控件用
    for g in layouts {
        let r = cursor.rowCount - 1 - Int((g.baseY / rowHeight).rounded())
        for x in g.xs {
            let key = "\(r):\(Int(x.rounded()))"
            expectedSlots[key, default: 0] += 1
        }
    }

    var matched = 0
    var unmatched: [NSView] = []
    for v in controls {
        let key = "\(rowOf(v)):\(Int(v.frame.minX.rounded()))"
        if let n = expectedSlots[key], n > 0 {
            expectedSlots[key] = n - 1
            matched += 1
        } else {
            unmatched.append(v)
        }
    }
    check("★ 31 个占位坐标都被真实控件用上（没有错位/漏摆）",
          matched == 31, "匹配 \(matched) / 31")
    check("没有未被用掉的占位坐标",
          expectedSlots.values.allSatisfy { $0 == 0 },
          "剩余 \(expectedSlots.values.filter { $0 > 0 }.count) 个")

    // 唯一的例外：线宽数值标签不单独占位，它挂在滑块槽位内部（widthX + 72）。
    // 这是有意的 —— 把它算成独立占位会让线宽组凭空多占 32pt。
    check("未匹配的控件只有 1 个，且是线宽数值标签",
          unmatched.count == 1
            && unmatched[0] is NSTextField
            && abs(unmatched[0].frame.height - 14) < 0.5,
          unmatched.map { "\(type(of: $0)) h=\(Int($0.frame.height))" }.joined(separator: ", "))

    // 控件不能互相重叠（坐标错位最典型的症状）
    var overlaps = 0
    for r in Set(controls.map(rowOf)) {
        let inRow = controls.filter { rowOf($0) == r }.sorted { $0.frame.minX < $1.frame.minX }
        for (a, b) in zip(inRow, inRow.dropFirst()) where a.frame.maxX > b.frame.minX + 0.5 {
            // 线宽标签与滑块同槽位，是有意的内含关系，不算重叠
            if a is NSSlider && b is NSTextField { continue }
            overlaps += 1
        }
    }
    check("同一行内控件不重叠（线宽标签内含于滑块槽位除外）", overlaps == 0, "\(overlaps) 处")

    // 窗口宽度仍由真实排布决定，且不超屏
    check("窗口宽度 ≤ 屏幕可见宽度", window.frame.width <= screen.width,
          String(format: "%.0f vs %.0f", window.frame.width, screen.width))
    check("工具栏框宽 ≥ 游标量出的内容宽（控件不会被裁掉）",
          toolbar.frame.width >= cursor.contentWidth - 0.5,
          String(format: "%.0f vs %.0f", toolbar.frame.width, cursor.contentWidth))
}

print("\n=== 6. 色块数变化时预算跟着变（证明没有写死）===\n")
do {
    let counts = ColorPalette.allPalettes.map { $0.colors.count }
    let unique = Array(Set(counts)).sorted()
    check("调色板里至少有两种色块数（否则这条测不出东西）", unique.count >= 2,
          unique.map { "\($0)" }.joined(separator: " / "))

    let baseline = AnnotationWindow.measureToolbarGroupWidths(paletteColorCount: unique[0])
    var previous: CGFloat = -1
    var monotone = true
    for n in unique {
        let w = AnnotationWindow.measureToolbarGroupWidths(paletteColorCount: n)
        check("色块 \(n) 个 → 颜色组宽 \(Int(48 + CGFloat(n) * 30))",
              w[3] == 48 + CGFloat(n) * 30, "\(Int(w[3]))")
        if previous >= 0 && w[3] <= previous { monotone = false }
        previous = w[3]
        // 除颜色组外，其余 11 组都不该受色块数影响
        let others = (0..<12).filter { $0 != 3 }
        check("色块 \(n) 个：其余 11 组宽度逐个不变",
              others.allSatisfy { w[$0] == baseline[$0] },
              others.filter { w[$0] != baseline[$0] }.map { "组\($0)" }.joined(separator: " "))
    }
    check("颜色组宽随色块数单调增", monotone)
}

print("\n=== 通过 \(pass)，失败 \(fail) ===")
exit(fail == 0 ? 0 : 1)