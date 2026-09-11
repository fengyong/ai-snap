import Cocoa

// 复现 HitTestBuffer 的精确条件：DeviceRGB + premultipliedLast + 关抗锯齿
let width = 256, height = 64
let colorSpace = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(
    data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.setShouldAntialias(false)
ctx.setAllowsAntialiasing(false)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

// 与 HitTestBuffer.colorFromKey 完全一致的实现
func keyColor(_ key: UInt32) -> NSColor {
    let r = CGFloat((key >> 16) & 0xFF) / 255.0
    let g = CGFloat((key >> 8) & 0xFF) / 255.0
    let b = CGFloat(key & 0xFF) / 255.0
    return NSColor(red: r, green: g, blue: b, alpha: 1.0)
}

// 与 HitTestBuffer.pickColorKey 完全一致的读取（含 Y 翻转）
func readKey(_ x: Int, _ y: Int) -> UInt32 {
    guard let data = ctx.data else { return 999 }
    let flippedY = height - 1 - y
    let ptr = data.assumingMemoryBound(to: UInt8.self)
    let off = flippedY * ctx.bytesPerRow + x * 4
    return (UInt32(ptr[off]) << 16) | (UInt32(ptr[off+1]) << 8) | UInt32(ptr[off+2])
}

print("========== 测试 1：纯色填充的 key 保真度（Generic RGB → DeviceRGB 转换） ==========")
let testKeys: [UInt32] = [1, 2, 3, 5, 10, 100, 255, 256, 4096, 0x0101, 0x00FF00, 0xFF0000,
                          0x0000AA, 0x00AA00, 0xAA0000, 0xFFFFFF, 0x123456, 0x0F0F0F]
var fail = 0
for (i, key) in testKeys.enumerated() {
    let x0 = i * 14
    ctx.setFillColor(keyColor(key).cgColor)
    ctx.fill(CGRect(x: CGFloat(x0), y: 0, width: 12, height: CGFloat(height)))
    let got = readKey(x0 + 6, height / 2)
    let ok = got == key
    if !ok {
        fail += 1
        let r = (key >> 16) & 0xFF, g = (key >> 8) & 0xFF, b = key & 0xFF
        let gr = (got >> 16) & 0xFF, gg = (got >> 8) & 0xFF, gb = got & 0xFF
        print("  ❌ key \(key) (\(r),\(g),\(b)) → 读回 \(got) (\(gr),\(gg),\(gb))")
    }
}
print(fail == 0 ? "  ✅ 全部 \(testKeys.count) 个 key 填充后逐字节保真" : "  共 \(fail) 个 key 失真")

print("========== 测试 2：描边（模拟 Arrow.drawArrow, lw+6） ==========")
ctx.setFillColor(NSColor.black.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
let key5 = keyColor(0x000005)
ctx.setStrokeColor(key5.cgColor)
ctx.setLineWidth(21)   // 默认 lineWidth 15 + 6
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 8, y: 32))
ctx.addLine(to: CGPoint(x: width - 8, y: 32))
ctx.strokePath()
let center = readKey(128, 32)
print(center == 5 ? "  ✅ 描边中心 = key 5，精确" : "  ❌ 描边中心 = \(center)")

// 描边外的中间色检查：整列扫描，非 key5 非 0 的即混色泄漏
var intermediates = 0
for yy in 0..<height {
    let k = readKey(128, yy)
    if k != 5 && k != 0 {
        intermediates += 1
        if intermediates <= 5 { print("  ⚠️ 中间色 y=\(yy) → \(k)") }
    }
}
print(intermediates == 0
    ? "  ✅ 整列无中间色（关抗锯齿生效，像素非此即彼）"
    : "  ❌ 存在 \(intermediates) 个混色像素")

print("========== 测试 3：虚线描边的命中空洞（lineStyle = .dashed, dash 8,4） ==========")
ctx.setFillColor(NSColor.black.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
ctx.setStrokeColor(keyColor(0x000007).cgColor)
ctx.setLineWidth(21)
ctx.setLineDash(phase: 0, lengths: [8, 4])
ctx.move(to: CGPoint(x: 8, y: 32))
ctx.addLine(to: CGPoint(x: width - 8, y: 32))
ctx.strokePath()
var miss = 0, total = 0
for xx in stride(from: 8, to: width - 8, by: 1) {
    total += 1
    if readKey(xx, 32) != 7 { miss += 1 }
}
print("  轴线上 \(miss)/\(total) 个采样点落在虚线空隙（点击无响应）")

print("========== 测试 4：Z 序覆盖（后画的覆盖先画的） ==========")
ctx.setFillColor(NSColor.black.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
ctx.setFillColor(keyColor(0x00000A).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
ctx.setFillColor(keyColor(0x00000B).cgColor)
ctx.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
let overlap = readKey(30, 30)
print(overlap == 0x0B ? "  ✅ 顶层对象覆盖底层，读回 0x0B" : "  ❌ 读回 \(overlap)")

print("========== 测试 5：Y 翻转正确性 ==========")
ctx.setFillColor(NSColor.black.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
ctx.setFillColor(keyColor(0x0000CC).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))   // 绘图坐标 y:0..10 = 底部
let bottomRead = readKey(5, 0)     // 视图坐标 y=0 也应是底部
let topRead = readKey(5, height - 1)
print(bottomRead == 0xCC && topRead == 0
    ? "  ✅ 绘图 y=0（底） ↔ 读图 y=0（底），翻转正确"
    : "  ❌ bottom=\(bottomRead) top=\(topRead)")

print("========== 测试 6：saveGState/rotate 后 key 是否保真（模拟旋转形状） ==========")
ctx.setFillColor(NSColor.black.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
ctx.saveGState()
ctx.translateBy(x: 128, y: 32)
ctx.rotate(by: .pi / 6)
ctx.setStrokeColor(keyColor(0x00AA00).cgColor)
ctx.setLineWidth(9)
ctx.stroke(CGRect(x: -20, y: -10, width: 40, height: 20))
ctx.restoreGState()
// 旋转后矩形长轴上的点：(22,6) 附近
var found = false
for dx in -30...30 {
    let px = 128 + dx, py = 32 + dx / 3
    if readKey(px, py) == 0xAA00 { found = true; break }
}
print(found ? "  ✅ 旋转描边 key 保真" : "  ❌ 旋转描边读不到正确 key")
