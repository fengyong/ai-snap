import CoreGraphics

// 工具栏折行算法（链接真实的 Sources/ToolbarLayout.swift）。
//
// 这段算法存在的理由很具体：工具栏按组折行时，**贪心**（装不下就换行）在
// "总宽只超一点点"的情况下会把最后一个组单独挤到下一行 —— 11 个组切出
// 「第一行 10 个、第二行 1 个」，比不折还难看。所以这里用线性分割求
// 「各段之和的最大值最小」的切法，让各行尽量接近。
//
// 本文件钉住的就是这条：均衡，而不是"塞满再换行"。

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
    else { fail += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
}

func widths(_ rows: [ToolbarLayout.Row], _ source: [CGFloat]) -> [CGFloat] {
    rows.map { r in r.range.reduce(CGFloat.zero) { $0 + source[$1] } }
}

print("=== 1. balancedRows 的基本行为 ===\n")
do {
    let w: [CGFloat] = [100, 100, 100, 100]
    check("1 行 = 全部元素", ToolbarLayout.balancedRows(widths: w, rows: 1) == [0..<4])
    check("4 行 = 每元素一行",
          ToolbarLayout.balancedRows(widths: w, rows: 4)
            == [0..<1, 1..<2, 2..<3, 3..<4])
    check("rows = 0 → nil", ToolbarLayout.balancedRows(widths: w, rows: 0) == nil)
    check("rows > 元素数 → nil", ToolbarLayout.balancedRows(widths: w, rows: 5) == nil)
    check("空输入 → nil", ToolbarLayout.balancedRows(widths: [], rows: 1) == nil)
}

print("\n=== 2. ★ 均衡，而不是「塞满再换行」 ===\n")
do {
    // 总宽 400、上限 310：贪心会给 [300, 100]，均衡应给 [200, 200]
    let w: [CGFloat] = [100, 100, 100, 100]
    let rows = ToolbarLayout.wrap(widths: w, limit: 310)
    let got = widths(rows, w)
    check("2 行", rows.count == 2, "\(rows.count)")
    check("两行等宽 200 / 200（贪心会切成 300 / 100）",
          got == [200, 200], got.map { "\(Int($0))" }.joined(separator: " / "))

    // 真实工具栏的尺度：11 个组，总宽约 1483，上限 1449
    let real: [CGFloat] = [483, 96, 88, 172, 116, 88, 70, 136, 126, 64, 44]
    let realRows = ToolbarLayout.wrap(widths: real, limit: 1449)
    let realWidths = widths(realRows, real)
    check("真实宽度下折成 2 行", realRows.count == 2, "\(realRows.count)")
    let spread = (realWidths.max() ?? 0) - (realWidths.min() ?? 0)
    check("两行宽度接近（相差 < 40%）",
          spread < (realWidths.max() ?? 1) * 0.4,
          realWidths.map { "\(Int($0))" }.joined(separator: " / "))
    check("没有任何一行只有一个组（不是被挤下来的尾巴）",
          realRows.allSatisfy { $0.range.count > 1 },
          "各行的组数 " + realRows.map { "\($0.range.count)" }.joined(separator: " / "))
}

print("\n=== 3. 行数随上限单调 ===\n")
do {
    let w: [CGFloat] = [483, 96, 88, 172, 116, 88, 70, 136, 126, 64, 44]
    let total = w.reduce(0, +)
    check("上限 ≥ 总宽 → 1 行", ToolbarLayout.wrap(widths: w, limit: total).count == 1)
    check("上限 = 总宽 - 1 → 折行",
          ToolbarLayout.wrap(widths: w, limit: total - 1).count > 1)

    // 上限越小，行数越多（单调不减）
    var previous = 0
    var monotone = true
    for limit in stride(from: total, through: 200, by: -50) {
        let n = ToolbarLayout.wrap(widths: w, limit: limit).count
        if n < previous { monotone = false }
        previous = n
    }
    check("上限递减时行数不减少", monotone)

    // 每个组都必须被排进去，且不重不漏
    for limit in [total, 1449, 800, 400, 200] {
        let rows = ToolbarLayout.wrap(widths: w, limit: limit)
        let covered = rows.flatMap { Array($0.range) }
        check("limit \(Int(limit))：11 个组不重不漏地覆盖",
              covered == Array(0..<11), "\(covered.count) 个")
    }
}

print("\n=== 4. 极端输入不崩 ===\n")
do {
    check("空输入 → 空结果", ToolbarLayout.wrap(widths: [], limit: 100).isEmpty)
    let one = ToolbarLayout.wrap(widths: [50], limit: 10)
    check("单个组比上限还宽 → 仍返回它（允许溢出，不丢内容）",
          one.count == 1 && one[0].range == 0..<1)
    let huge = ToolbarLayout.wrap(widths: [10, 10, 10], limit: 0)
    check("上限为 0 → 每元素一行，不丢内容",
          huge.count == 3 && huge.flatMap { Array($0.range) } == [0, 1, 2])
}

print("\n=== 5. widthLimit：窗口不能比屏幕宽 ===\n")
do {
    check("比屏幕窄 24 点", ToolbarLayout.widthLimit(screenVisibleWidth: 1473) == 1449,
          "\(ToolbarLayout.widthLimit(screenVisibleWidth: 1473))")
    check("不小于 320（极窄屏也不能窄到没法用）",
          ToolbarLayout.widthLimit(screenVisibleWidth: 200) == 320,
          "\(ToolbarLayout.widthLimit(screenVisibleWidth: 200))")
    for screenWidth in [5120.0, 2560.0, 1473.0, 1440.0, 1280.0, 1024.0] {
        let limit = ToolbarLayout.widthLimit(screenVisibleWidth: screenWidth)
        check("屏幕 \(Int(screenWidth)) → 上限 \(Int(limit)) ≤ 屏宽",
              limit <= screenWidth)
    }
}

print("\n=== 6. 不同屏幕宽度下，工具栏实际折几行 ===\n")
do {
    let w: [CGFloat] = [483, 96, 88, 172, 116, 88, 70, 136, 126, 64, 44]
    for screenWidth in [2560.0, 1473.0, 1280.0, 1024.0] {
        let limit = ToolbarLayout.widthLimit(screenVisibleWidth: screenWidth)
        let rows = ToolbarLayout.wrap(widths: w, limit: limit)
        let ws = widths(rows, w)
        print(String(format: "  屏宽 %5.0f → 上限 %4.0f → %d 行，最宽一行 %.0f",
                     screenWidth, limit, rows.count, ws.max() ?? 0))
        check("最宽一行 ≤ 上限（窗口不会超屏）", (ws.max() ?? 0) <= limit)
    }
}

print("=== 通过 \(pass)，失败 \(fail) ===")
exit(fail == 0 ? 0 : 1)
