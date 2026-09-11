import Accelerate
import Cocoa

// 找出「真正做面积平均」且够快的降采样实现。
// 判据：50/50 黑白条纹 → 每块都应恰好 ≈128；左黑右白 → 左块 0、右块 255。

func makeImage(width: Int, height: Int,
               _ fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b, a) = fill(x, y)
            let i = (y * width + x) * 4
            buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = a
        }
    }
    return ctx.makeImage()!
}

func pixels(_ image: CGImage) -> (w: Int, h: Int, data: [UInt8]) {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    return (w, h, Array(UnsafeBufferPointer(start: buf, count: w * h * 4)))
}

func rowGray(_ p: (w: Int, h: Int, data: [UInt8]), _ y: Int) -> [Int] {
    (0..<p.w).map { Int(p.data[(y * p.w + $0) * 4]) }
}

// MARK: 候选实现

/// A: CG 上下文绘制（当前实现），可调插值质量
func cgDownscale(_ image: CGImage, block: Int, quality: CGInterpolationQuality) -> CGImage? {
    let cols = max(1, Int((Double(image.width) / Double(block)).rounded(.up)))
    let rows = max(1, Int((Double(image.height) / Double(block)).rounded(.up)))
    let ctx = CGContext(data: nil, width: cols, height: rows,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = quality
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
    return ctx.makeImage()
}

/// B: 手写整数面积平均（严格箱式）
func manualDownscale(_ image: CGImage, block: Int) -> CGImage? {
    let w = image.width, h = image.height
    let cols = max(1, Int((Double(w) / Double(block)).rounded(.up)))
    let rows = max(1, Int((Double(h) / Double(block)).rounded(.up)))

    // 先把源图重绘进已知 RGBA8 布局（CGImage 的来源格式不可假定）
    let src = CGContext(data: nil, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    src.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let input = src.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)

    let out = CGContext(data: nil, width: cols, height: rows,
                        bitsPerComponent: 8, bytesPerRow: cols * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let dst = out.data!.bindMemory(to: UInt8.self, capacity: cols * rows * 4)

    for by in 0..<rows {
        let y0 = by * block, y1 = min(y0 + block, h)
        for bx in 0..<cols {
            let x0 = bx * block, x1 = min(x0 + block, w)
            var r = 0, g = 0, b = 0, a = 0, n = 0
            for y in y0..<y1 {
                var i = (y * w + x0) * 4
                for _ in x0..<x1 {
                    r += Int(input[i]); g += Int(input[i + 1])
                    b += Int(input[i + 2]); a += Int(input[i + 3])
                    n += 1; i += 4
                }
            }
            let o = (by * cols + bx) * 4
            dst[o] = UInt8(r / n); dst[o + 1] = UInt8(g / n)
            dst[o + 2] = UInt8(b / n); dst[o + 3] = UInt8(a / n)
        }
    }
    return out.makeImage()
}

/// C: Accelerate vImage（flags 0 = 简单箱式；带 kvImageHighQualityResampling 是 Lanczos）
///
/// 布局说明：vImage 的 ARGB8888 在小端机器上就是 BGRA 字节序，所以两端都用
/// `premultipliedFirst` 建上下文，否则通道会被错位解释。
func vImageDownscale(_ image: CGImage, block: Int, highQuality: Bool) -> CGImage? {
    let w = image.width, h = image.height
    let cols = max(1, Int((Double(w) / Double(block)).rounded(.up)))
    let rows = max(1, Int((Double(h) / Double(block)).rounded(.up)))

    guard let srcCtx = CGContext(data: nil, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue),
          let dstCtx = CGContext(data: nil, width: cols, height: rows,
                                 bitsPerComponent: 8, bytesPerRow: cols * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return nil }

    srcCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var src = vImage_Buffer(data: srcCtx.data,
                            height: vImagePixelCount(h), width: vImagePixelCount(w),
                            rowBytes: w * 4)
    var dst = vImage_Buffer(data: dstCtx.data,
                            height: vImagePixelCount(rows), width: vImagePixelCount(cols),
                            rowBytes: cols * 4)

    let flags = highQuality ? vImage_Flags(kvImageHighQualityResampling)
                            : vImage_Flags(kvImageNoFlags)
    guard vImageScale_ARGB8888(&src, &dst, nil, flags) == kvImageNoError else { return nil }
    return dstCtx.makeImage()
}

// MARK: 判据

let stripes = makeImage(width: 80, height: 80) { x, _ in
    (x / 2) % 2 == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255)
}
let half = makeImage(width: 80, height: 80) { x, _ in
    x < 40 ? (0, 0, 0, 255) : (255, 255, 255, 255)
}

print("判据一：50/50 黑白条纹按块 20 降采样 → 每块都应 ≈128（面积平均）")
print("判据二：左黑右白按块 20 降采样 → 左两块 0、右两块 255（不串色）\n")

func report(_ name: String, _ image: CGImage?) {
    guard let image = image else { print("  \(name): nil"); return }
    let p = pixels(image)
    let s = rowGray(p, 0)
    let h = rowGray(pixels(half), 0)
    let stripeOK = s.allSatisfy { abs($0 - 128) <= 8 }
    let halfOK = h == [0, 0, 255, 255]
    print("  \(name)")
    print("    条纹 → \(s.map(String.init).joined(separator: " "))   \(stripeOK ? "✅ 面积平均" : "❌")")
    print("    左黑右白 → \(h.map(String.init).joined(separator: " "))   \(halfOK ? "✅ 不串色" : "❌ 串色")")
}

print("=== 候选实现 ===")
report("A1 CG .high（当前实现）", cgDownscale(stripes, block: 20, quality: .high))
report("A2 CG .medium", cgDownscale(stripes, block: 20, quality: .medium))
report("A3 CG .low", cgDownscale(stripes, block: 20, quality: .low))
report("B  手写整数面积平均", manualDownscale(stripes, block: 20))
report("C1 vImage flags 0", vImageDownscale(stripes, block: 20, highQuality: false))
report("C2 vImage 高质量重采样", vImageDownscale(stripes, block: 20, highQuality: true))

// 左黑右白要单独用各自的图测
print("\n=== 左黑右白（判据二，各实现单独跑）===")
for (name, fn) in [
    ("A1 CG .high", { cgDownscale(half, block: 20, quality: .high) }),
    ("A2 CG .medium", { cgDownscale(half, block: 20, quality: .medium) }),
    ("A3 CG .low", { cgDownscale(half, block: 20, quality: .low) }),
    ("B  手写面积平均", { manualDownscale(half, block: 20) }),
    ("C1 vImage flags 0", { vImageDownscale(half, block: 20, highQuality: false) }),
] as [(String, () -> CGImage?)] {
    if let img = fn() {
        let h = rowGray(pixels(img), 0)
        print("  \(name): \(h.map(String.init).joined(separator: " "))")
    } else { print("  \(name): nil") }
}

// MARK: 性能

print("\n=== 性能：整屏 2560×1600 → 块 24（107×67），各 7 次取中位 ===")
let big = makeImage(width: 2560, height: 1600) { x, y in
    (UInt8(x % 256), UInt8(y % 256), 128, 255)
}
func timeIt(_ n: Int, _ body: () -> Void) -> Double {
    var t: [Double] = []
    for _ in 0..<n {
        let s = CFAbsoluteTimeGetCurrent()
        body()
        t.append((CFAbsoluteTimeGetCurrent() - s) * 1000)
    }
    return t.sorted()[t.count / 2]
}

// 强制实现（读出像素），否则可能只记了个延迟任务
func force(_ img: CGImage?) {
    guard let img = img else { return }
    let c = CGContext(data: nil, width: img.width, height: img.height,
                      bitsPerComponent: 8, bytesPerRow: img.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    _ = c.data!.bindMemory(to: UInt8.self, capacity: 4)[0]
}

print(String(format: "  A1 CG .high     : %.2f ms", timeIt(7) { force(cgDownscale(big, block: 24, quality: .high)) }))
print(String(format: "  A2 CG .medium   : %.2f ms", timeIt(7) { force(cgDownscale(big, block: 24, quality: .medium)) }))
print(String(format: "  B  手写面积平均 : %.2f ms", timeIt(7) { force(manualDownscale(big, block: 24)) }))
print(String(format: "  C1 vImage       : %.2f ms", timeIt(7) { force(vImageDownscale(big, block: 24, highQuality: false)) }))

print("\n=== 小区域（400×300，块 24）—— 更常见的实际场景 ===")
let small = makeImage(width: 400, height: 300) { x, y in
    (UInt8(x % 256), UInt8(y % 256), 128, 255)
}
print(String(format: "  A1 CG .high     : %.3f ms", timeIt(9) { force(cgDownscale(small, block: 24, quality: .high)) }))
print(String(format: "  A2 CG .medium   : %.3f ms", timeIt(9) { force(cgDownscale(small, block: 24, quality: .medium)) }))
print(String(format: "  B  手写面积平均 : %.3f ms", timeIt(9) { force(manualDownscale(small, block: 24)) }))
print(String(format: "  C1 vImage       : %.3f ms", timeIt(9) { force(vImageDownscale(small, block: 24, highQuality: false)) }))
