// 滚动长截图拼接算法的 spike 探针（纯 CoreGraphics，离屏可跑）。
//
// 这是滚动长截图功能唯一的高风险点：偏移量估算错了，拼出来的长图就是
// 错位/重影的 —— 必须先离屏证明「合成图上偏移量识别 100% 准」才值得
// 投入功能层（CGEvent 滚动驱动 + 实机调各 app 的滚动语义）。
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

/// 确定性纹理（LCG）：**行基序列非周期**（每行一个独立伪随机基色 +
/// 微幅像素噪声）。
///
/// 第一版用 `y*7` 做行间变化 —— 行均值是周期 ≈36.6 行的锯齿波，
/// 相关峰到处都是、偏移量识别全错（探针自己抓出来的）：行投影法匹配的是
/// 「行均值的序列」，测试数据的行均值必须有唯一性，就像真实 UI 的行内容那样。
func textureImage(width: Int, height: Int, seed: UInt64) -> CGImage {
    var rs = seed
    var rowBase = [UInt8](repeating: 0, count: height)
    for y in 0..<height {
        rs = rs &* 6364136223846793005 &+ 1442695040888963407
        rowBase[y] = UInt8(truncatingIfNeeded: rs >> 33)
    }
    var state = seed &+ 0x9E3779B97F4A7C15
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = UInt8(truncatingIfNeeded: state >> 40) & 15   // ±8 幅度
            let o = (y * width + x) * 4
            bytes[o] = rowBase[y] &+ noise
            bytes[o + 1] = rowBase[y] &+ noise
            bytes[o + 2] = rowBase[y]
            bytes[o + 3] = 255
        }
    }
    let ctx = CGContext(data: &bytes, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

/// 取图像顶部第 fromRow 行起的 height 行（CGImage.cropping 的 y 是**顶部**原点）。
/// A = 原图前 400 行（滚动前的屏幕），B = 从 shift 行起的后一屏 ——
/// 与算法假设「B 在 A 下方延续」同向。
func cropRows(_ image: CGImage, fromRow: Int, height: Int) -> CGImage {
    image.cropping(to: CGRect(x: 0, y: CGFloat(fromRow),
                              width: CGFloat(image.width), height: CGFloat(height)))!
}

print("=== 1. 偏移量识别（合成图上必须 100% 准）===\n")
do {
    let width = 300, heightA = 400, heightB = 400
    let a = textureImage(width: width, height: heightA, seed: 42)
    // B = 长内容里从 shift 行起的下一屏：B.row j == 原图 row (shift + j)
    for shift in [40, 80, 120, 200] {
        let source = textureImage(width: width, height: heightA + shift, seed: 42)
        let b = cropRows(source, fromRow: shift, height: heightB)
        // B 的前 (heightA - shift) 行与 A 的末 (heightA - shift) 行重叠
        let expected = heightA - shift
        let got = ImageStitch.verticalOverlap(imageA: a, imageB: b)
        check("shift \(shift) → 重叠 \(expected) 行", got == expected,
              "got=\(String(describing: got))")
    }
}

print("\n=== 2. 拼接结果 ===\n")
do {
    let width = 300, height = 400, shift = 120
    let source = textureImage(width: width, height: height + shift, seed: 42)
    let a = cropRows(source, fromRow: 0, height: height)
    let b = cropRows(source, fromRow: shift, height: height)
    let overlap = height - shift   // 280
    guard let stitched = ImageStitch.stitchVertical(a, b, overlap: overlap) else {
        check("拼接返回非 nil", false); exit(1)
    }
    check("拼接高度 = A + B - 重叠", stitched.height == height + shift,
          "\(stitched.height) vs \(height + shift)")
    // 接缝校验：拼接图第 (height-1) 行应等于原图第 (height-1) 行，
    // 第 height 行应等于原图第 height 行（跨过接缝连续）
    let rep = NSBitmapImageRep(cgImage: stitched)
    func pixelAt(_ x: Int, _ row: Int) -> Int {
        // 拼接图 row r == 原图 row r（r < height+shift），CG 左下原点 → 位图 y 翻转
        rep.colorAt(x: x, y: stitched.height - 1 - row)
            .map { Int($0.redComponent * 255) } ?? -1
    }
    let seamA = pixelAt(150, height - 1)   // A 的最后一行
    let seamB = pixelAt(150, height)       // B 的第一个新行
    let origA = NSBitmapImageRep(cgImage: source)
    func origPixel(_ x: Int, _ row: Int) -> Int {
        origA.colorAt(x: x, y: source.height - 1 - row)
            .map { Int($0.redComponent * 255) } ?? -1
    }
    check("接缝上侧 = 原图第 \(height-1) 行", abs(seamA - origPixel(150, height - 1)) <= 2,
          "\(seamA) vs \(origPixel(150, height - 1))")
    check("接缝下侧 = 原图第 \(height) 行", abs(seamB - origPixel(150, height)) <= 2,
          "\(seamB) vs \(origPixel(150, height))")
}

print("\n=== 3. 不可拼的情况要如实返回 nil ===\n")
do {
    // 两张毫无关系的图：重叠区相关度过不了阈值
    let a = textureImage(width: 200, height: 300, seed: 1)
    let b = textureImage(width: 200, height: 300, seed: 999)
    let got = ImageStitch.verticalOverlap(imageA: a, imageB: b)
    check("无关图返回 nil", got == nil, "got=\(String(describing: got))")

    // 纯色图（零方差）返回 nil，不是崩、不是假峰
    let solid = CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    solid.setFillColor(NSColor.white.cgColor)
    solid.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
    let white = solid.makeImage()!
    check("纯色图返回 nil（零方差保护）",
          ImageStitch.verticalOverlap(imageA: white, imageB: white) == nil)
}

print("\n=== 4. 性能预算 ===\n")
do {
    // 一次配对（估算 + 拼接）的预算：滚动采帧 2-4 帧/秒，单帧配对必须 ≪ 250ms
    let a = textureImage(width: 800, height: 600, seed: 7)
    let source = textureImage(width: 800, height: 720, seed: 7)
    let b = cropRows(source, fromRow: 120, height: 600)
    let t0 = Date()
    _ = ImageStitch.verticalOverlap(imageA: a, imageB: b)
    let estimate = Date().timeIntervalSince(t0)
    let t1 = Date()
    _ = ImageStitch.stitchVertical(a, b, overlap: 480)
    let stitch = Date().timeIntervalSince(t1)
    check("800×600 估算 < 100ms（实测 \(Int(estimate * 1000))ms）", estimate < 0.1)
    check("800×600 拼接 < 50ms（实测 \(Int(stitch * 1000))ms）", stitch < 0.05)
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
