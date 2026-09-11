import CoreGraphics

// AnchoredPlacement 的验证：就地编辑时窗口落在哪、工具栏挂哪一侧。
//
// 为什么必须靠探针：这几条边界（选区贴屏幕底边/顶边/右边、窗口比屏幕还宽）
// 只在特定屏幕上复现，而**离屏进程里 NSScreen.main 是 nil** —— 直接在
// AnnotationWindow 上测根本走不到这些分支。抽成纯函数就是为了能在这里算一遍。
//
// 链接真实源码 Sources/AnchoredPlacement.swift。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

let toolbar: CGFloat = 48
/// 假想屏幕：1440×900，原点在左下（AppKit 全局坐标）
let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

/// 就地编辑的窗口尺寸与选区是绑定的：画布就是选区本身（不做缩放适配），
/// 所以窗口高 = 选区高 + 工具栏高。这一点很关键 —— 用它才能算出真实边界。
func windowSize(for anchor: CGRect, width: CGFloat = 1200) -> CGSize {
    CGSize(width: width, height: anchor.height + toolbar)
}

func place(_ anchor: CGRect, width: CGFloat = 1200) -> AnchoredPlacement.Result {
    AnchoredPlacement.compute(anchor: anchor, windowSize: windowSize(for: anchor, width: width),
                              toolbarHeight: toolbar, screenFrame: screen)
}

/// 「画布底边正好压在选区底边上」——这是就地编辑的核心不变量。
/// 工具栏在下方时画布从 origin.y + toolbar 起，在上方时从 origin.y 起。
func canvasBottom(_ r: AnchoredPlacement.Result) -> CGFloat {
    r.origin.y + (r.toolbarAtTop ? 0 : toolbar)
}

/// 工具栏整条是否在屏幕内 —— **这才是整个修复真正要保证的东西**：
/// 出屏的是「保存 / 复制 / 贴图」这些按钮，用户点不到。
func toolbarFullyOnScreen(_ r: AnchoredPlacement.Result, windowHeight: CGFloat) -> Bool {
    let lower = r.toolbarAtTop ? r.origin.y + windowHeight - toolbar : r.origin.y
    return lower >= screen.minY && lower + toolbar <= screen.maxY
}

print("=== 1. 常规情况：工具栏在下方，画布压在选区上 ===")
do {
    let anchor = CGRect(x: 100, y: 300, width: 400, height: 200)
    let r = place(anchor)
    check("工具栏在下方", r.toolbarAtTop == false)
    check("窗口底边 = 选区底边 − 工具栏高",
          r.origin.y == 300 - toolbar, "\(r.origin.y)")
    check("画布底边 == 选区底边（核心不变量）",
          canvasBottom(r) == anchor.minY, "\(canvasBottom(r)) vs \(anchor.minY)")
    check("水平左对齐选区", r.origin.x == 100, "\(r.origin.x)")
    check("工具栏整条在屏幕内",
          toolbarFullyOnScreen(r, windowHeight: windowSize(for: anchor).height))
}

print("\n=== 2. 选区贴屏幕最底部 → 工具栏翻到画布上方（画布仍压在选区上）===")
do {
    // 这是评审揪出的真问题：不改的话 origin.y = 5 − 48 = −43，整条工具栏沉出屏
    let anchor = CGRect(x: 100, y: 5, width: 400, height: 200)
    let r = place(anchor)
    check("工具栏翻到上方", r.toolbarAtTop == true)
    check("窗口底边 == 选区底边（不再为负）", r.origin.y == 5, "\(r.origin.y)")
    check("窗口不出屏（底边 ≥ 屏幕底边）", r.origin.y >= screen.minY)
    check("画布底边仍 == 选区底边（翻边后对齐不丢）",
          canvasBottom(r) == anchor.minY, "\(canvasBottom(r)) vs \(anchor.minY)")
    check("工具栏整条在屏幕内（翻边后按钮仍然够得着）",
          toolbarFullyOnScreen(r, windowHeight: windowSize(for: anchor).height))

    // 极端一点：贴底且只有 1 点高
    let thin = place(CGRect(x: 0, y: 0, width: 300, height: 1))
    check("贴底且极扁的选区也翻边成功", thin.toolbarAtTop == true, "\(thin)")
    check("极扁选区也不出屏", thin.origin.y >= screen.minY)
}

print("\n=== 3. 放不下时退化为夹取（画布对齐牺牲，但按钮必须够得着）===")
do {
    // 贴底 + 几乎满高 ⇒ 翻到上方会顶出屏幕顶边，两种朝向都放不下
    let anchor = CGRect(x: 100, y: 5, width: 400, height: 880)
    let r = place(anchor)
    check("宽度不变", r.origin.x == 100)
    check("回退到「工具栏在下方」", r.toolbarAtTop == false)
    check("窗口底边被夹到屏幕底边", r.origin.y == screen.minY, "\(r.origin.y)")
    // 注：窗口（928）比屏幕（900）还高时，"顶边也不出屏"物理上做不到。
    // 这种极端情况下唯一还能保证的是**工具栏整条可见** —— 画布上沿被切可以接受，
    // 按钮点不到不行。我第一版把这条也断言成"顶边不出屏"，是预期写错了。
    check("窗口比屏幕还高时，工具栏仍整条在屏幕内（按钮够得着）",
          toolbarFullyOnScreen(r, windowHeight: windowSize(for: anchor).height),
          "\(r)")
}

print("\n=== 4. 水平方向：右边缘左移，左边缘不动 ===")
do {
    // 窗口宽 1200，屏幕 1440 ⇒ 可放范围 x ∈ [0, 240]
    let right = place(CGRect(x: 1300, y: 300, width: 100, height: 200))
    check("贴右边缘时左移，右边界不出屏",
          right.origin.x == 240, "\(right.origin.x)")
    check("左移后仍在屏幕内", right.origin.x >= screen.minX)

    let left = place(CGRect(x: 0, y: 300, width: 100, height: 200))
    check("贴左边缘时保持不动", left.origin.x == 0, "\(left.origin.x)")

    // 窗口比屏幕还宽：只能顶到 0，不允许出现负值（否则左侧控件会被推到屏幕外）
    let wider = place(CGRect(x: 700, y: 300, width: 100, height: 200), width: 1600)
    check("窗口比屏幕还宽时 x 夹到 0（不出现负值）", wider.origin.x == 0,
          "\(wider.origin.x)")
}

print("\n=== 5. 负坐标屏（副屏在左/下方）也不能算错 ===")
do {
    let offLeft = CGRect(x: -1920, y: 0, width: 1440, height: 900)
    let r = AnchoredPlacement.compute(
        anchor: CGRect(x: -1800, y: 300, width: 400, height: 200),
        windowSize: CGSize(width: 1200, height: 248),
        toolbarHeight: toolbar, screenFrame: offLeft)
    check("副屏上用该屏自己的 frame 判定（不假定原点为 0）",
          r.origin.x == -1800 && r.origin.y == 300 - toolbar,
          "\(r.origin)")
}

print("\n=== 6. 退化输入不崩、不返回 NaN ===")
do {
    let zero = AnchoredPlacement.compute(anchor: CGRect(x: 10, y: 10, width: 0, height: 0),
                                         windowSize: .zero, toolbarHeight: toolbar,
                                         screenFrame: screen)
    check("零尺寸窗口返回未夹取的落点（不崩）", zero.origin.x == 10 && zero.origin.y == -38,
          "\(zero.origin)")

    let noScreen = AnchoredPlacement.compute(
        anchor: CGRect(x: 10, y: 10, width: 100, height: 100),
        windowSize: CGSize(width: 200, height: 148),
        toolbarHeight: toolbar, screenFrame: .zero)
    check("屏幕 frame 为空时也不产生 NaN",
          !noScreen.origin.x.isNaN && !noScreen.origin.y.isNaN, "\(noScreen.origin)")
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
