// 窗口选择模式纯逻辑的探针：候选筛选复用 windowCandidates（它自身已在
// master_parity_probe 里验证），这里专查 WindowPickSupport 新增的三件事：
// Quartz → AppKit 的矩形翻转（含副屏负坐标）、标题拼接、滚轮换选回绕。
// 错任何一条的表现都是「高亮的窗口 ≠ 截到的窗口」，静默错误必须离屏钉死。
import Cocoa

setbuf(stdout, nil)   // 无缓冲：崩溃时已打印的断言不丢

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

// 注意字典值的类型：kCGWindowBounds 的值必须是 CGFloat（windowCandidates 里是
// `as? [String: CGFloat]`）、pid Int32、layer Int、alpha Double —— 用错会整条
// 静默转换失败（master_parity_probe 合成用例时踩过的坑，此处沿用）。
func win(_ id: UInt32, pid: Int32,
         _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
         layer: Int = 0, alpha: Double = 1.0,
         name: String? = nil, owner: String? = nil) -> [String: Any] {
    var dict: [String: Any] = [
        kCGWindowNumber as String: id,
        kCGWindowOwnerPID as String: pid,
        kCGWindowLayer as String: layer,
        kCGWindowAlpha as String: alpha,
        kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
    ]
    if let name { dict[kCGWindowName as String] = name }
    if let owner { dict[kCGWindowOwnerName as String] = owner }
    return dict
}

let primaryHeight: CGFloat = 1080

print("=== 1. Quartz → AppKit 翻转（主屏）===\n")
do {
    // Quartz (100, 200, 300, 400)：顶边在 Quartz y=200 → AppKit 底边 y = 1080-200 = 880，
    // 底边在 Quartz y=600 → AppKit 顶边 y = 1080-600 = 480 → frame.origin.y = 480
    let list = [win(1, pid: 900, 100, 200, 300, 400, name: "终端", owner: "Terminal")]
    let got = WindowPickSupport.candidates(from: list, at: CGPoint(x: 200, y: 700),
                                           primaryScreenHeight: primaryHeight, ownPID: 999)
    check("命中 1 个候选", got.count == 1)
    check("frame 翻转为 AppKit (100, 480, 300, 400)",
          got.first?.frame == CGRect(x: 100, y: 480, width: 300, height: 400),
          "\(got.first?.frame ?? .zero)")
    check("命中点用 AppKit 坐标（窗口内）", got.first?.id == 1)
}

print("\n=== 2. 副屏负坐标（主屏上方的屏）===\n")
do {
    // 主屏上方的屏：AppKit y 从 1080 起（1080…2062）。Quartz y = 1080 - appKitY - h
    // → appKit frame (0, 1100, 1512, 982) 对应 Quartz (0, -1002, 1512, 982)。
    let list = [win(7, pid: 901, 0, -1002, 1512, 982, name: "Xcode", owner: "Xcode")]
    // 光标在 AppKit (10, 1200)（副屏上）→ Quartz (10, -120)，应命中
    let got = WindowPickSupport.candidates(from: list, at: CGPoint(x: 10, y: 1200),
                                           primaryScreenHeight: primaryHeight, ownPID: 999)
    check("上方副屏的窗口被命中（负 Quartz 坐标路径）", got.first?.id == 7,
          "\(got.map(\.id))")
    check("AppKit frame 落在副屏范围 (y ≥ 1080)",
          (got.first?.frame.minY ?? -1) >= 1080, "\(got.first?.frame ?? .zero)")
}

print("\n=== 3. 标题拼接 ===\n")
do {
    let list = [
        win(1, pid: 900, 0, 0, 100, 100, name: "设计与验收", owner: "Figma"),
        win(2, pid: 901, 0, 0, 100, 100, name: "Untitled", owner: nil),
        win(3, pid: 902, 0, 0, 100, 100, name: nil, owner: "Safari"),
        win(4, pid: 903, 0, 0, 100, 100),
    ]
    // 窗口在 Quartz (0,0,100,100) = AppKit y 980…1080；命中点用 AppKit (50, 1030)
    let got = WindowPickSupport.candidates(from: list, at: CGPoint(x: 50, y: 1030),
                                           primaryScreenHeight: primaryHeight, ownPID: 999)
    guard got.count == 4 else {
        check("4 个候选全命中", false, "\(got.map(\.id))")
        exit(1)
    }
    check("两个都有 → 「窗口名 — 应用名」", got[0].title == "设计与验收 — Figma", got[0].title)
    check("只有窗口名 → 取窗口名", got[1].title == "Untitled", got[1].title)
    check("只有应用名 → 取应用名", got[2].title == "Safari", got[2].title)
    check("都空 → 空串（显示端兜底「未命名窗口」）", got[3].title == "", "\"\(got[3].title)\"")
}

print("\n=== 4. Z 序保持（滚轮换选的顺序基准）===\n")
do {
    let list = [
        win(11, pid: 900, 0, 0, 400, 400, layer: 3),   // 浮层（最前）
        win(12, pid: 901, 0, 0, 400, 400),
        win(13, pid: 902, 0, 0, 400, 400),
    ]
    // 窗口在 Quartz (0,0,400,400) = AppKit y 680…1080；命中点用 AppKit (10, 1070)
    let got = WindowPickSupport.candidates(from: list, at: CGPoint(x: 10, y: 1070),
                                           primaryScreenHeight: primaryHeight, ownPID: 999)
    check("候选保持 Z 序 [11, 12, 13]", got.map(\.id) == [11, 12, 13], "\(got.map(\.id))")
}

print("\n=== 5. 滚轮换选回绕（与工具切换共用 CyclicIndex）===\n")
do {
    // 下滚（scrollUp=false）正向；上滚反向；到头回绕
    check("0 下滚 → 1", WindowPickSupport.steppedCandidateIndex(current: 0, count: 3, scrollUp: false) == 1)
    check("2 下滚 → 0（回绕）", WindowPickSupport.steppedCandidateIndex(current: 2, count: 3, scrollUp: false) == 0)
    check("0 上滚 → 2（回绕）", WindowPickSupport.steppedCandidateIndex(current: 0, count: 3, scrollUp: true) == 2)
    check("单候选下滚仍在 0", WindowPickSupport.steppedCandidateIndex(current: 0, count: 1, scrollUp: false) == 0)
    check("空列表给 0", WindowPickSupport.steppedCandidateIndex(current: nil, count: 0, scrollUp: false) == 0)
}

print("\n=== 6. 选区吸附（SelectionSnapping）===")
do {
    let frames = [
        CGRect(x: 0, y: 0, width: 800, height: 600),        // 窗口 A
        CGRect(x: 900, y: 100, width: 400, height: 300),    // 窗口 B
    ]
    // 右边距窗口 A 右边 3pt → 吸上
    let r1 = SelectionSnapping.snapped(CGRect(x: 10, y: 10, width: 793, height: 400),
                                       toWindowFrames: frames)
    check("3pt 内贴上窗口右边", r1.rect.maxX == 800, "\(r1.rect)")
    check("报告被吸附的窗口框", r1.snappedFrame == frames[0])
    // 距离超阈值不吸
    let r2 = SelectionSnapping.snapped(CGRect(x: 10, y: 10, width: 780, height: 400),
                                       toWindowFrames: frames)
    check("20pt 外不吸附", r2.rect.width == 780 && r2.snappedFrame == nil, "\(r2.rect)")
    // 多边吸附：左边/右边贴 A 的左右边，**底边跨边贴 A 的顶边**（600）
    let r3 = SelectionSnapping.snapped(CGRect(x: 3, y: 597, width: 794, height: 300),
                                       toWindowFrames: frames)
    check("三边吸附（含底边跨边贴窗口顶边）",
          r3.rect.minX == 0 && r3.rect.maxX == 800 && r3.rect.minY == 600
          && r3.rect.maxY == 897, "\(r3.rect)")
    // 防塌缩：细条压在窗口右边上，左右两条边都想吸到 800 —— 该轴放弃吸附，宽度保持
    let r5 = SelectionSnapping.snapped(CGRect(x: 799, y: 100, width: 2, height: 50),
                                       toWindowFrames: [frames[0]])
    check("同轴防塌缩（宽度保持 2）", r5.rect == CGRect(x: 799, y: 100, width: 2, height: 50),
          "\(r5.rect)")
    // 空清单原样返回
    let r4 = SelectionSnapping.snapped(CGRect(x: 1, y: 2, width: 3, height: 4),
                                       toWindowFrames: [])
    check("空清单原样返回", r4.rect == CGRect(x: 1, y: 2, width: 3, height: 4)
          && r4.snappedFrame == nil)
    // allWindowFrames：Quartz → AppKit 翻转（复用窗口清单）
    let list = [win(21, pid: 900, 100, 200, 300, 400)]
    let appKitFrames = WindowPickSupport.allWindowFrames(
        from: list, primaryScreenHeight: primaryHeight, ownPID: 999)
    check("allWindowFrames 翻转为 AppKit (100, 480, 300, 400)",
          appKitFrames == [CGRect(x: 100, y: 480, width: 300, height: 400)],
          "\(appKitFrames)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
