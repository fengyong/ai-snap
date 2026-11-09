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
// 状态（2026-11-09）：全部转绿。P1-6 以「PinWindow.isReleasedWhenClosed = true」修复 ——
// NSApp.windows 对关闭后的窗口仍是强引用，unregister 摘不掉这条链；置 true 让
// AppKit 在 close() 里摘除并释放（close() override 已保证先 unregister 再 super.close）。
// 原 §3/§5 是「泄漏存在性」的旧行为记录，随修复翻转为不累积断言。
//
//      run_probe pin_lifetime_probe    Sources/Pin/PinWindow.swift Sources/Pin/PinManager.swift
//
// 注意：它只依赖 PinWindow + PinManager 两个文件，**不需要**整模块编译。
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

print("=== 1. 关闭后 NSApp.windows 不再持有窗口（P1-6 已修）===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    let pin = PinWindow(image: makeImage(400, 300),
                        frame: NSRect(x: 100, y: 100, width: 400, height: 300))
    pin.orderFrontRegardless()
    pin.close()
    check("close 后 NSApp.windows 回到 baseline（isReleasedWhenClosed = true）",
          NSApp.windows.count == baseline,
          "baseline=\(baseline) → \(NSApp.windows.count)")
}

print("\n=== 2. 单张开关的等价形态（显式置 true，兜底语义不变）===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    let pin = PinWindow(image: makeImage(400, 300),
                        frame: NSRect(x: 100, y: 100, width: 400, height: 300))
    pin.isReleasedWhenClosed = true
    pin.orderFrontRegardless()
    pin.close()
    check("显式置 true 后 NSApp.windows 回到 baseline", NSApp.windows.count == baseline,
          "baseline=\(baseline) → \(NSApp.windows.count)")
}

print("\n=== 3. 累积速率：10 次「贴图 → 关闭」不累积 ===\n")
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
    check("10 次开关净增 0（旧实现净增 10 = 泄漏，每张约 20MB）", after == baseline,
          "baseline=\(baseline) → \(after)（净增 \(after - baseline)）")
}

print("\n=== 4. 走真实生产路径（PinManager.shared.pin）同样不累积 ===\n")
do {
    _ = NSApplication.shared
    let baseline = NSApp.windows.count
    for _ in 0..<5 {
        let pin = PinManager.shared.pin(makeImage(400, 300))
        pin.close()
    }
    let after = NSApp.windows.count
    check("PinManager 路径净增 0（unregister + close 即释放）",
          after == baseline,
          "baseline=\(baseline) → \(after)（净增 \(after - baseline)）")
    check("PinManager.count 已归零（说明 unregister 确实执行了）",
          PinManager.shared.count == 0, "count=\(PinManager.shared.count)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
