import Cocoa

// 目的：在改代码之前，先用离屏上下文验证「虚线修复方案」能否真正产生间隙。
// 复现 HitTestBuffer 的上下文参数（DeviceRGB + premultipliedLast + 关抗锯齿）。
let width = 320, height = 48
let colorSpace = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(
    data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.setShouldAntialias(false)
ctx.setAllowsAntialiasing(false)

func readKey(_ x: Int, _ y: Int) -> UInt32 {
    guard let data = ctx.data else { return 999 }
    let flippedY = height - 1 - y
    let ptr = data.assumingMemoryBound(to: UInt8.self)
    let off = flippedY * ctx.bytesPerRow + x * 4
    return (UInt32(ptr[off]) << 16) | (UInt32(ptr[off + 1]) << 8) | UInt32(ptr[off + 2])
}

func keyColor(_ key: UInt32, _ cs: CGColorSpace) -> CGColor {
    let r = CGFloat((key >> 16) & 0xFF) / 255.0
    let g = CGFloat((key >> 8) & 0xFF) / 255.0
    let b = CGFloat(key & 0xFF) / 255.0
    return CGColor(colorSpace: cs, components: [r, g, b, 1.0])!
}

/// 画一条水平线，返回轴线上「非该 key」的采样点数量（即空隙数）
func gaps(dash: [CGFloat], cap: CGLineCap, lw: CGFloat, key: UInt32) -> (gap: Int, total: Int) {
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setStrokeColor(keyColor(key, colorSpace))
    ctx.setLineWidth(lw)
    ctx.setLineCap(cap)
    ctx.setLineDash(phase: 0, lengths: dash)
    ctx.move(to: CGPoint(x: 10, y: CGFloat(height) / 2))
    ctx.addLine(to: CGPoint(x: CGFloat(width - 10), y: CGFloat(height) / 2))
    ctx.strokePath()

    var miss = 0, total = 0
    // 在轴线中心上下各取一行，避免只采到圆头边缘
    for xx in 10..<(width - 10) {
        total += 1
        if readKey(xx, height / 2) != key { miss += 1 }
    }
    return (miss, total)
}

print("线宽取默认值 15（AnnotationView.currentLineWidth 的初始值）\n")

// A. 当前实现：round cap + [8, 4]
let a = gaps(dash: [8, 4], cap: .round, lw: 15, key: 0x01)
print("A 当前实现   round + [8,4]     空隙 \(a.gap)/\(a.total)  \(a.gap == 0 ? "→ 实线（bug 复现）" : "")")

// B. 当前实现（审计用的 lw=21，picking 路径）
let b = gaps(dash: [8, 4], cap: .round, lw: 21, key: 0x02)
print("B 当前实现   round + [8,4] lw21 空隙 \(b.gap)/\(b.total)  \(b.gap == 0 ? "→ 实线" : "")")

// C. 修复方案 · 虚线：butt cap + [3w, 2w]
let c = gaps(dash: [45, 30], cap: .butt, lw: 15, key: 0x03)
print("C 修复·虚线  butt  + [3w,2w]   空隙 \(c.gap)/\(c.total)  \(c.gap > 0 ? "→ 有间隙 ✅" : "→ 仍为实线 ❌")")

// D. 修复方案 · 点线：round cap + [1, 2w]
let d = gaps(dash: [1, 30], cap: .round, lw: 15, key: 0x04)
print("D 修复·点线  round + [1,2w]    空隙 \(d.gap)/\(d.total)  \(d.gap > 0 ? "→ 有间隙 ✅" : "→ 仍为实线 ❌")")

// E. picking 路径强制实线（应无空隙，保证虚线对象仍可整段点中）
let e = gaps(dash: [], cap: .round, lw: 21, key: 0x05)
print("E picking 强制实线             空隙 \(e.gap)/\(e.total)  \(e.gap == 0 ? "→ 可整段命中 ✅" : "→ 有空隙 ❌")")

print("\n--- 粗细敏感性：修复方案在其它线宽下是否仍成立 ---")
for lw in [1.0, 2.0, 4.0, 8.0, 15.0, 30.0] as [CGFloat] {
    let r = gaps(dash: [lw * 3, lw * 2], cap: .butt, lw: lw, key: 0x06)
    let duty = Double(r.gap) / Double(r.total) * 100
    print(String(format: "  线宽 %5.1f  空隙占比 %5.1f%%  %@", lw, duty, r.gap > 0 ? "✅" : "❌"))
}
