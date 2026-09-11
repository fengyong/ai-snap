import Cocoa

// 打码验证：块平均是不是真的平均、模糊边缘有没有发暗、放大有没有被插值糊掉、
// 细密图案（模拟小字）有没有被真正抹平、以及每帧绘制成本撑不撑得住拖拽预览。
//
// 编译时链接**真实的** ImageRedaction.swift + ScreenGeometry.swift + Models.swift +
// RedactionShape.swift，测的就是要发布的那份代码。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

// MARK: - Helpers

func makeImage(width: Int, height: Int, _ fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
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

/// 把图重绘进固定 RGBA8 上下文再读像素 —— 不这样读，拿到的格式取决于来源。
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

func gray(_ p: (w: Int, h: Int, data: [UInt8]), _ x: Int, _ y: Int) -> Int {
    Int(p.data[(y * p.w + x) * 4])
}

func canvasContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func median(_ n: Int, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    for _ in 0..<n {
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    return samples.sorted()[samples.count / 2]
}

// MARK: - 1. 马赛克：块平均

print("=== 1. 马赛克是「块平均」，不是「取块里第一个像素」===")
do {
    let half = makeImage(width: 40, height: 40) { x, _ in
        x < 20 ? (0, 0, 0, 255) : (255, 255, 255, 255)
    }
    let out = ImageRedaction.blockAverages(half, blockSize: 40)!
    let p = pixels(out)
    check("40×40 整块 → 输出 1×1", p.w == 1 && p.h == 1, "\(p.w)×\(p.h)")
    let v = gray(p, 0, 0)
    check("黑白各半 → 平均值 ≈128（若取首像素会是 0）", abs(v - 128) <= 12, "实测 \(v)")

    // 首像素纯红、其余纯蓝：能把"取首像素"的实现直接判死（那样会得到纯红）
    let redFirst = makeImage(width: 20, height: 20) { x, y in
        (x == 0 && y == 0) ? (255, 0, 0, 255) : (0, 0, 255, 255)
    }
    let p2 = pixels(ImageRedaction.blockAverages(redFirst, blockSize: 20)!)
    let r = Int(p2.data[0]), b = Int(p2.data[2])
    check("首像素红、其余蓝 → 结果以蓝为主", b > 240 && r < 20, "R=\(r) B=\(b)")
}

// MARK: - 2. 输出尺寸 = 分块数

print("\n=== 2. 小图尺寸 = ceil(宽/块) × ceil(高/块) ===")
do {
    let img = makeImage(width: 100, height: 60) { _, _ in (10, 10, 10, 255) }
    let a = pixels(ImageRedaction.blockAverages(img, blockSize: 10)!)
    check("100×60 / 块10 → 10×6", a.w == 10 && a.h == 6, "\(a.w)×\(a.h)")
    let b = pixels(ImageRedaction.blockAverages(img, blockSize: 30)!)
    check("100×60 / 块30 → 4×2（向上取整）", b.w == 4 && b.h == 2, "\(b.w)×\(b.h)")
    let c = pixels(ImageRedaction.blockAverages(img, blockSize: 999)!)
    check("块大于图 → 仍为 1×1（不能退化成 0）", c.w == 1 && c.h == 1, "\(c.w)×\(c.h)")
}

// MARK: - 3. 放大是硬边；串扰有界

print("\n=== 3. 放大用最近邻 → 色块硬边；块间串扰有界 ===")
do {
    let img = makeImage(width: 100, height: 20) { x, _ in
        x < 50 ? (0, 0, 0, 255) : (255, 255, 255, 255)
    }
    let out = pixels(ImageRedaction.pixelate(img, blockSize: 10)!)
    check("尺寸还原为 100×20", out.w == 100 && out.h == 20, "\(out.w)×\(out.h)")

    check("块内像素完全一致", gray(out, 41, 10) == gray(out, 49, 10), "x=41 与 x=49")
    // 块宽 10、边界落在 0/10/20…50，所以过渡在 x=49→50。
    // （第一版我写的是 39→41，那两块其实同属第 4 块 —— 用 `.high` 时它"恰好"变了，
    //  改用精确平均后同块同值，才暴露出是我对照值写错。这是本轮第三次同类问题。）
    check("跨块立刻变化（无过渡带）", gray(out, 49, 10) != gray(out, 50, 10), "x=49 与 x=50")

    // 交界处不能互相串色。这一条曾经是失败的 —— 当时用的是 `.high`，而 `.high` 是
    // 带振铃的 Lanczos 核，会把邻块内容"过冲"进来（实测 20 / 235）。改用 `.medium`
    // 后才是真正的面积平均。参见 ImageRedaction.blockAverages 里的对照表。
    let left = gray(out, 45, 10), right = gray(out, 55, 10)
    check("交界两侧是纯黑/纯白（精确面积平均，不串色）",
          left == 0 && right == 255, "左块=\(left) 右块=\(right)")
}

// MARK: - 4. 隐私：细密图案必须被抹平

print("\n=== 4. 隐私要求：块内的细密图案（模拟小字）必须被抹平成均匀色 ===")
do {
    // 2 像素黑白相间 ≈ 屏幕上的小号正文
    let stripes = makeImage(width: 80, height: 80) { x, _ in
        (x / 2) % 2 == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255)
    }
    // 注意：源图的对比度要逐像素量，采样步长不能与条纹周期（4）成整数倍，
    // 否则会整行都采到同一个颜色 —— 我第一版就是 stride 4，误判成"原图全黑"。
    let before = pixels(stripes)
    var bMin = 255, bMax = 0
    for i in stride(from: 0, to: 80 * 80 * 4, by: 4) {
        let v = Int(before.data[i]); bMin = min(bMin, v); bMax = max(bMax, v)
    }
    check("原图确实是高对比条纹（对照）", bMax - bMin >= 200, "\(bMin)…\(bMax)")

    let flat = pixels(ImageRedaction.pixelate(stripes, blockSize: 20)!)
    var fMin = 255, fMax = 0
    for i in stride(from: 0, to: 80 * 80 * 4, by: 4) {
        let v = Int(flat.data[i]); fMin = min(fMin, v); fMax = max(fMax, v)
    }
    check("打码后高对比被抹平成单一灰度", fMax - fMin <= 4, "输出灰度范围 \(fMin)…\(fMax)")
    check("抹平后正好是原图的中位值（说明是精确平均）",
          abs(fMin - 128) <= 4, "\(fMin)")

    // 极端情形：整块只有一点点内容，也要被充分打散
    let nearly = makeImage(width: 60, height: 60) { x, y in
        (x < 3 && y < 3) ? (0, 0, 0, 255) : (255, 255, 255, 255)
    }
    let nearlyOut = pixels(ImageRedaction.pixelate(nearly, blockSize: 60)!)
    check("整块只有 9/3600 是黑色 → 输出仍接近白（说明是真平均）",
          gray(nearlyOut, 30, 30) > 240, "\(gray(nearlyOut, 30, 30))")
}

// MARK: - 5. 模糊：边缘不能发暗

print("\n=== 5. 高斯模糊：纯色图模糊后边缘仍是原色（不能被「透明」晕开）===")
do {
    let flat = makeImage(width: 64, height: 64) { _, _ in (128, 128, 128, 255) }
    let blurred = pixels(ImageRedaction.blur(flat, radius: 8)!)
    check("中心保持 128", abs(gray(blurred, 32, 32) - 128) <= 3, "\(gray(blurred, 32, 32))")
    check("角点保持 128（未变暗 → 说明先 clampedToExtent 了）",
          abs(gray(blurred, 1, 1) - 128) <= 4, "\(gray(blurred, 1, 1))")
    check("上边缘保持 128", abs(gray(blurred, 32, 0) - 128) <= 4, "\(gray(blurred, 32, 0))")

    // 对照：不钳制会得到什么。有对照，上面那条断言才有意义。
    let input = CIImage(cgImage: flat)
    let noClamp = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 8.0])
        .cropped(to: input.extent)
    if let cg = CIContext().createCGImage(noClamp, from: input.extent) {
        print("     （对照）不钳制时角点 = \(gray(pixels(cg), 1, 1))，钳制后 = \(gray(blurred, 1, 1))")
    }
}

// MARK: - 6. 模糊确实降低锐度

print("\n=== 6. 模糊确实把锐利边界摊开了 ===")
do {
    let img = makeImage(width: 64, height: 64) { x, _ in
        x < 32 ? (0, 0, 0, 255) : (255, 255, 255, 255)
    }
    let before = pixels(img)
    let after = pixels(ImageRedaction.blur(img, radius: 6)!)
    check("原图边界跳变 255", gray(before, 32, 32) - gray(before, 31, 32) == 255)
    let atEdge = gray(after, 32, 32)
    check("模糊后边界处是中间值", atEdge > 40 && atEdge < 215, "\(atEdge)")
    check("模糊后短距离内不再有满跳变",
          abs(gray(after, 32, 32) - gray(after, 36, 32)) < 200)
}

// MARK: - 7. 点 → 像素换算、旋转覆盖

print("\n=== 7. RedactionShape 的换算与旋转覆盖 ===")
do {
    let source = makeImage(width: 200, height: 100) { _, _ in (200, 60, 60, 255) }
    let shape = RedactionShape(center: CGPoint(x: 30, y: 20), width: 20, height: 10,
                               style: .mosaic(blockSize: 12), hitTestColorKey: 7)
    shape.sourceImage = source
    shape.pixelScale = 2
    check("取样矩形 = 形状自身（未旋转）",
          shape.sampleRect == CGRect(x: 20, y: 15, width: 20, height: 10),
          "\(shape.sampleRect)")

    let pixelRect = ScreenGeometry.pixelRect(
        appKitRect: shape.sampleRect.standardized,
        imageSize: CGSize(width: 200, height: 100),
        appKitScreenFrame: CGRect(x: 0, y: 0, width: 100, height: 50))
    check("对应像素区域 = 40×20（倍率生效）",
          pixelRect.width == 40 && pixelRect.height == 20, "\(pixelRect)")

    let small = pixels(ImageRedaction.blockAverages(source, blockSize: 12)!)
    check("块 12 像素作用于 200×100 → 17×9", small.w == 17 && small.h == 9,
          "\(small.w)×\(small.h)")

    // 旋转后取样区变成外接矩形，保证覆盖完整（不漏出未打码像素）
    let rot = RedactionShape(center: CGPoint(x: 50, y: 50), width: 40, height: 20,
                             style: .blur(radius: 12), hitTestColorKey: 1)
    let upright = rot.sampleRect
    rot.rotate(by: .pi / 4)
    let rotated = rot.sampleRect
    check("未旋转时取样区 = 形状自身",
          upright == CGRect(x: 30, y: 40, width: 40, height: 20), "\(upright)")
    check("旋转后外接矩形变大",
          rotated.width * rotated.height > upright.width * upright.height,
          "\(Int(upright.width * upright.height)) → \(Int(rotated.width * rotated.height))")
    check("旋转后四个角点仍被取样区包含（不会漏出未打码像素）",
          rot.cornerPoints().allSatisfy {
              rotated.insetBy(dx: -0.01, dy: -0.01).contains($0)
          })
}

// MARK: - 8. 每帧成本（走真实的 draw 路径）

print("\n=== 8. 每帧绘制成本（整屏 2560×1600 = 1280×800 点，Retina 2×）===")
do {
    let source = makeImage(width: 2560, height: 1600) { x, y in
        (UInt8(x % 256), UInt8(y % 256), 128, 255)
    }
    let canvas = canvasContext(width: 1280, height: 800)
    let budget = 1000.0 / 120.0      // 120Hz 帧预算 8.33ms

    let mosaic = RedactionShape(center: CGPoint(x: 640, y: 400), width: 1280, height: 800,
                                style: .mosaic(blockSize: 12), hitTestColorKey: 1)
    mosaic.sourceImage = source
    mosaic.pixelScale = 2
    mosaic.draw(in: canvas)                                  // 暖机：首次构建贴图
    let mosaicFrame = median(15) { mosaic.draw(in: canvas) }

    let blur = RedactionShape(center: CGPoint(x: 640, y: 400), width: 1280, height: 800,
                              style: .blur(radius: 12), hitTestColorKey: 2)
    blur.sourceImage = source
    blur.pixelScale = 2
    blur.draw(in: canvas)
    let blurFrame = median(15) { blur.draw(in: canvas) }

    print(String(format: "     马赛克每帧：%.2f ms", mosaicFrame))
    print(String(format: "     模糊每帧：  %.2f ms", blurFrame))
    print(String(format: "     120Hz 帧预算：%.2f ms", budget))
    check("马赛克每帧 ≤ 1/3 帧预算", mosaicFrame <= budget / 3,
          String(format: "%.2f ms", mosaicFrame))
    check("模糊每帧 ≤ 1/3 帧预算", blurFrame <= budget / 3,
          String(format: "%.2f ms", blurFrame))

    // 尺寸变化时才付的代价（拖拽预览每帧都会变尺寸，所以这个数字才是拖拽的瓶颈）
    let build = median(7) {
        let s = RedactionShape(center: CGPoint(x: 640, y: 400),
                               width: 1279, height: 799,
                               style: .mosaic(blockSize: 12), hitTestColorKey: 3)
        s.sourceImage = source
        s.pixelScale = 2
        s.draw(in: canvas)
    }
    print(String(format: "     尺寸变化时重建贴图（拖拽预览每帧都付）：%.2f ms", build))
    check("拖拽预览每帧 ≤ 1 个帧预算", build <= budget,
          String(format: "%.2f ms", build))

    // 对照：上一版"每帧把小图放大铺满"的策略
    let small = ImageRedaction.blockAverages(source, blockSize: 24)!
    let oldWay = median(15) {
        canvas.interpolationQuality = .none
        canvas.draw(small, in: CGRect(x: 0, y: 0, width: 1280, height: 800))
    }
    print(String(format: "     （对照）上一版每帧放大铺满：%.2f ms", oldWay))
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
