// 贴图（Pin）窗口的生命周期探针 —— 判定「关闭贴图后是否真的释放」。
//
// 背景：2026-10-23 的代码评审报告列了 P1-6「Pin 关闭后从不释放」
// （依据是 `isReleasedWhenClosed = false` + `NSApp.windows` 强引用）；
// 同日的《修复计划》§1.3/§9.3 把它判为「不成立、不修」，依据是
// `PinWindow.close()` override 先 `PinManager.unregister(self)` 摘掉数组引用。
//
// 关键分歧点：unregister 只摘掉了 **PinManager 数组**的引用，
// 真正决定窗口会不会被留下的，是 **NSApp.windows** 这条链。
//
// 判据用 **NSApp.windows 的计数**：它不受 ARC 生命周期延长、也不受
// autorelease pool 未排空的干扰，是这里唯一无歧义的信号。
// （weak 引用在本探针里不可靠：`NSWindow.close()` 会把窗口放进当前
//   autorelease pool，探针没有 run loop，池在程序结束前不会排空 →
//   weak 恒非 nil。手工开 pool 排空又会让 AppKit 在无 run loop 的情况下
//   释放仍登记着的窗口 → 段错误。故一律以计数为准。）
//
// 编译：swiftc Sources/Pin/PinWindow.swift Sources/Pin/PinManager.swift probes/pin_lifetime_probe.swift
//
// 状态（2026-10-23）：**已注册**为常驻回归，但仍是「已知红灯」——
// 6 项里 §1 还在红（批次 4 / P1-6：关闭后的贴图窗口仍被 NSApp.windows 留住）。
//
//      run_probe pin_lifetime_probe    Sources/Pin/PinWindow.swift Sources/Pin/PinManager.swift
//
// 注意：它只依赖 PinWindow + PinManager 两个文件，**不需要**整模块编译。
// §1 转绿后，run_all.sh 会提示「已转绿，请从 EXPECTED_FAIL 移除」。
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}
func info(_ label: String, _ detail: String) {
    print("  ℹ️  \(label)  → \(detail)")
}

func makeImage(_ w: Int, _ h: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    img.unlockFocus()
    return img
}

print("=== 1. 现状（isReleasedWhenClosed = false）：窗口是否留在 NSApp.windows ===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    let pin = PinWindow(image: makeImage(400, 300),
                        frame: NSRect(x: 100, y: 100, width: 400, height: 300))
    pin.orderFrontRegardless()
    pin.close()
    check("close 后 NSApp.windows 不再含该窗口（当前实现做不到）",
          NSApp.windows.count == baseline,
          "baseline=\(baseline) → \(NSApp.windows.count)（仍被 AppKit 留着）")
}

print("\n=== 2. 修法（isReleasedWhenClosed = true）===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    let pin = PinWindow(image: makeImage(400, 300),
                        frame: NSRect(x: 100, y: 100, width: 400, height: 300))
    pin.isReleasedWhenClosed = true
    pin.orderFrontRegardless()
    pin.close()
    check("改 true 后 NSApp.windows 回到 baseline", NSApp.windows.count == baseline,
          "baseline=\(baseline) → \(NSApp.windows.count)")
}

print("\n=== 3. 累积速率（现状）：10 次「贴图 → 关闭」===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    for _ in 0..<10 {
        let pin = PinWindow(image: makeImage(400, 300),
                            frame: NSRect(x: 100, y: 100, width: 400, height: 300))
        pin.orderFrontRegardless()
        pin.close()
    }
    let after = NSApp.windows.count
    check("关闭后的窗口仍被留着（净增 10 = 泄漏）", after == baseline + 10,
          "baseline=\(baseline) → \(after)（净增 \(after - baseline)）")
    info("每个泄漏窗口持有", "整幅 NSImage + PinContentView.alphaMask（Retina 全屏约 20MB）")
}

print("\n=== 4. 累积速率（修法后）===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    for _ in 0..<10 {
        let pin = PinWindow(image: makeImage(400, 300),
                            frame: NSRect(x: 100, y: 100, width: 400, height: 300))
        pin.isReleasedWhenClosed = true
        pin.orderFrontRegardless()
        pin.close()
    }
    let after = NSApp.windows.count
    check("修法后不累积（净增 0）", after == baseline,
          "baseline=\(baseline) → \(after)（净增 \(after - baseline)）")
}

print("\n=== 5. 走真实生产路径（PinManager.shared.pin）===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    for _ in 0..<5 {
        let pin = PinManager.shared.pin(makeImage(400, 300))
        pin.close()
    }
    let after = NSApp.windows.count
    check("PinManager 路径同样泄漏（unregister 只摘数组引用）",
          after == baseline + 5,
          "baseline=\(baseline) → \(after)（净增 \(after - baseline)）")
    check("PinManager.count 已归零（说明 unregister 确实执行了）",
          PinManager.shared.count == 0, "count=\(PinManager.shared.count)")
    info("结论", "PinManager 侧干净，泄漏发生在 AppKit 的窗口列表这一侧")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
