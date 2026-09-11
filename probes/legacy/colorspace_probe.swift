import Cocoa

func spaceName(_ cs: CGColorSpace?) -> String {
    guard let cs, let n = cs.name else { return "nil" }
    return n as String
}

print("=== 1. 三种构造方式产出的 CGColor 色彩空间 ===")
let a = NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0).cgColor
print("NSColor(red:green:blue:).cgColor            → \(spaceName(a.colorSpace))")

let device = CGColorSpaceCreateDeviceRGB()
let b = CGColor(colorSpace: device, components: [0.5, 0.5, 0.5, 1.0])!
print("CGColor(colorSpace: DeviceRGB, ...)         → \(spaceName(b.colorSpace))")

let c = NSColor(cgColor: b)!.cgColor
print("NSColor(cgColor: DeviceRGB颜色).cgColor      → \(spaceName(c.colorSpace))")

print("\n=== 2. 分量是否逐字节一致（决定最小改法能否成立）===")
func comps(_ cg: CGColor) -> [Int] {
    guard let cs = cg.colorSpace,
          let ptr = cg.components else { return [] }
    let n = cg.numberOfComponents
    let dev = CGColorSpaceCreateDeviceRGB()
    let converted = cg.converted(to: dev, intent: .defaultIntent, options: nil) ?? cg
    _ = cs; _ = ptr
    guard let p2 = converted.components else { return [] }
    return (0..<min(n, p2.count)).map { Int((p2[$0] * 255).rounded()) }
}
print("NSColor(red:0.5,...) 转 DeviceRGB 后分量 → \(comps(a))  (期望 [128,128,128])")
print("DeviceRGB 直构 转 DeviceRGB 后分量        → \(comps(b))  (期望 [128,128,128])")
print("NSColor(cgColor:) 包装后分量              → \(comps(c))  (期望 [128,128,128])")

print("\n=== 3. 实际填充进 DeviceRGB 位图，读回字节 ===")
let w = 60, h = 8
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: device,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(false)

func fillAndRead(_ color: CGColor, x: Int) -> (Int, Int, Int) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 10, height: CGFloat(h)))
    let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let off = (h - 1 - h / 2) * ctx.bytesPerRow + (x + 5) * 4
    return (Int(ptr[off]), Int(ptr[off + 1]), Int(ptr[off + 2]))
}

// 用一组"最容易暴露色彩空间转换"的值：中间灰 + 极小分量
let probes: [(String, UInt32)] = [
    ("0x808080 中灰", 0x808080),
    ("0x010203 极小", 0x010203),
    ("0x7F7F7F 半灰", 0x7F7F7F),
]

for (label, key) in probes {
    let r = CGFloat((key >> 16) & 0xFF) / 255.0
    let g = CGFloat((key >> 8) & 0xFF) / 255.0
    let bl = CGFloat(key & 0xFF) / 255.0

    let viaNSColor = NSColor(red: r, green: g, blue: bl, alpha: 1.0).cgColor
    let viaDevice = CGColor(colorSpace: device, components: [r, g, bl, 1.0])!
    let viaWrap = NSColor(cgColor: viaDevice)!.cgColor

    let got1 = fillAndRead(viaNSColor, x: 0)
    let got2 = fillAndRead(viaDevice, x: 20)
    let got3 = fillAndRead(viaWrap, x: 40)

    let want = (Int((key >> 16) & 0xFF), Int((key >> 8) & 0xFF), Int(key & 0xFF))
    let f = { (t: (Int, Int, Int)) in "\(t.0),\(t.1),\(t.2)\(t == want ? "✅" : "❌")" }
    print("  \(label)  期望 \(want.0),\(want.1),\(want.2)")
    print("     NSColor(red:)        → \(f(got1))")
    print("     CGColor(DeviceRGB)   → \(f(got2))")
    print("     NSColor(cgColor:)    → \(f(got3))")
}
