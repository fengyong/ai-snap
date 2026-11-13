// 导出编码探针：验证 ImageEncode 的格式分发与数据合法性。
//
// PNG 沿用当初 AnnotationWindow.pngData 的逐位一致断言思路（那个转发层 2026-11-11 已删，见 O8）；
// JPEG/HEIC 是有损格式，
// 断言「数据存在 + 魔数正确」（逐像素比对对有损编码没有意义）。
// HEIC 编码器不是所有机器都有（虚拟机/老款机），本机不支持时如实记 INFO 跳过，
// 不算失败 —— 探针跑在其他机器上不能因为硬件能力假红。
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

// 4×4 纯红不透明图（bitmap rep，走 NSBitmapImageRep 主路径）
func redImage() -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<4 {
        for x in 0..<4 {
            rep.setColor(NSColor.red, atX: x, y: y)
        }
    }
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.addRepresentation(rep)
    return image
}

/// 4×4 带**透明边缘**的图：全透明 / 半透明 / 不透明 / 0.75 透明度各一像素。
///
/// 为什么必须用这张图而不是纯红图：贴图窗的真实风险是「alpha 被吃掉」，
/// 而全不透明的图上 alpha 无论丢没丢都看不出来 —— 拿它做像素比对等于没比。
func alphaImage() -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 0), atX: 0, y: 0)
    rep.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 0.5), atX: 1, y: 1)
    rep.setColor(NSColor.red, atX: 2, y: 2)
    rep.setColor(NSColor(deviceRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.75), atX: 3, y: 3)
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.addRepresentation(rep)
    return image
}

/// 解码一张 PNG 数据，逐像素取 sRGB 分量（用于**像素级**比对，不是字节比对）。
func pixels(_ data: Data?) -> [String] {
    guard let data, let rep = NSBitmapImageRep(data: data) else { return [] }
    var out: [String] = []
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            out.append(String(format: "%.3f,%.3f,%.3f,%.3f",
                              c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent))
        }
    }
    return out
}

/// 只取 alpha 通道（逐像素）。贴图的「透明边缘」是否还在，只看这一列。
func alphas(_ data: Data?) -> [CGFloat] {
    guard let data, let rep = NSBitmapImageRep(data: data) else { return [] }
    var out: [CGFloat] = []
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            out.append(c.alphaComponent)
        }
    }
    return out
}

let image = redImage()
func head(_ data: Data, _ n: Int) -> [UInt8] {
    Array(data.prefix(n))
}

print("=== 1. PNG（默认格式，行为必须与旧 pngData 一致）===\n")
do {
    let data = ImageEncode.data(from: image, url: URL(fileURLWithPath: "/tmp/x.png"))
    check("PNG 数据非 nil", data != nil)
    check("PNG 魔数 0x89 50 4E 47 (PNG signature)", head(data ?? Data(), 4) == [0x89, 0x50, 0x4E, 0x47],
          "\(head(data ?? Data(), 4))")
    // 2026-11-11（O8）：原先这里是「经 `AnnotationWindow.pngData` 薄包装再验一次」，
    // 那个转发层已删 —— 现在探针直接调 `ImageEncode`，验的就是生产代码真正走的那条路。
    // 这里只验分发，逐位一致断言在 master_parity_probe 的既有用例里。
}

print("\n=== 2. JPEG ===\n")
do {
    let data = ImageEncode.data(from: image, url: URL(fileURLWithPath: "/tmp/x.jpg"))
    check("JPG 扩展名 → JPEG 数据", data != nil && head(data ?? Data(), 2) == [0xFF, 0xD8],
          "\(head(data ?? Data(), 2))")
    let data2 = ImageEncode.data(from: image, url: URL(fileURLWithPath: "/tmp/x.jpeg"))
    check("JPEG 扩展名同样分发", data2 != nil && head(data2 ?? Data(), 2) == [0xFF, 0xD8])
}

print("\n=== 3. HEIC（编码器可用性因机器而异）===\n")
do {
    let data = ImageEncode.data(from: image, url: URL(fileURLWithPath: "/tmp/x.heic"))
    if let data, data.count > 12 {
        check("HEIC 数据存在且足够长", true, "\(data.count) 字节")
        // ISO BMFF 容器：第 4..8 字节是 'ftyp'
        let bytes = head(data, 8)
        let ftyp = String(bytes: bytes[4..<8], encoding: .ascii)
        check("HEIC 容器魔数 ftyp", ftyp == "ftyp", "\(ftyp ?? "?")")
    } else {
        print("  ⏭️  本机没有 HEIC 编码器（返回 nil）—— 如实跳过，不算失败")
    }
}

print("\n=== 4. 认不出的扩展名按 PNG 兜底 ===\n")
do {
    let data = ImageEncode.data(from: image, url: URL(fileURLWithPath: "/tmp/x.webp"))
    check("未知扩展名 → PNG 魔数", head(data ?? Data(), 4) == [0x89, 0x50, 0x4E, 0x47])
}

print("\n=== 5. 同一张图，两条入口产出相同字节（O8 编码单源化）===\n")
do {
    // 同一个语义曾有三份独立实现（导出 / 截图历史 / 贴图窗）。
    // 现在统一到 `ImageEncode`，NSImage 与 CGImage 两个入口必须**字节一致** ——
    // 不一致就说明还有一份实现没被收拢。
    for (label, img) in [("不透明图", image), ("带透明边缘图", alphaImage())] {
        let nsData = ImageEncode.png(from: img)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            check("能取到 CGImage（\(label)）", false); exit(1)
        }
        let cgData = ImageEncode.png(from: cg)
        check("CGImage 入口产出数据（\(label)）", cgData != nil)
        check("两条入口产出**字节完全一致**（\(label)）",
              nsData != nil && nsData == cgData,
              "\(nsData?.count ?? -1) vs \(cgData?.count ?? -1) 字节")
    }
}

print("\n=== 6. 像素级护栏：旧贴图路径（TIFF 往返）与新路径必须逐像素一致 ===\n")
do {
    // 旧贴图路径是「TIFF 往返 → NSBitmapImageRep → PNG」。去掉往返后字节会变
    // （实测 173 vs 161 字节），但**像素必须逐位相同** —— 贴图的透明边缘不能变。
    // 用带透明边缘的图比，否则 alpha 丢没丢根本看不出来。
    let img = alphaImage()
    guard let newData = ImageEncode.png(from: img) else {
        check("新路径能编码出数据", false); exit(1)
    }

    // 先验测试图本身确实带透明边缘：否则下面所有 alpha 断言都是空转。
    //
    // **必须读源图 rep，不能读编码输出**：读输出的话，编码器吃掉 alpha 时这条
    // 也会红，可它报的是"测试图没有透明边缘" —— 病灶在编码器，锅甩给了夹具。
    // 2026-11-12 用一个铺白底的坏编码器实测过这个误导：输出 alpha 全 1.00，
    // 于是排查会被引向"是不是测试图造错了"，而真正该看的是编码器。
    guard let srcRep = img.representations.first as? NSBitmapImageRep else {
        check("测试图是位图 rep（能直接读源像素）", false); exit(1)
    }
    var srcAlphas: [CGFloat] = []
    for y in 0..<srcRep.pixelsHigh {
        for x in 0..<srcRep.pixelsWide {
            // 2026-11-12 评审 P2-5：取不到色就**跳过**，不再用 -1 哨兵 ——
            // 哨兵会被下面的 `< 0.01` 当成"全透明"，只要另有正常半透明像素
            // 就能把"源图少读了一堆像素"这件事混过去。配合下面的源图像素计数。
            if let alpha = srcRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.alphaComponent {
                srcAlphas.append(alpha)
            }
        }
    }
    check("源图像素全部读到位（\(srcRep.pixelsWide)×\(srcRep.pixelsHigh)）",
          srcAlphas.count == srcRep.pixelsWide * srcRep.pixelsHigh,
          "读到 \(srcAlphas.count) / \(srcRep.pixelsWide * srcRep.pixelsHigh)")
    check("测试图确实带透明边缘（全透明 + 半透明各存在）",
          srcAlphas.contains(where: { $0 < 0.01 }) && srcAlphas.contains(where: { $0 > 0.01 && $0 < 0.99 }),
          "源图 alpha 分布 \(srcAlphas.map { String(format: "%.2f", $0) }.joined(separator: "/"))")

    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let legacy = rep.representation(using: .png, properties: [:]) {
        let legacyPixels = pixels(legacy), newPixels = pixels(newData)
        let legacyAlphas = alphas(legacy), newAlphas = alphas(newData)
        // 解码失败（或 colorAt 取不到色）时 pixels()/alphas() 返回空数组，
        // 于是 `[] == []` 会让下面的"逐像素一致"**真空通过**。先把"两侧各解出
        // 16 个像素"钉住 —— 解码失败与像素不等必须是两件分开报的事。
        // alpha 那条断言有同一个空洞，所以两侧都要数。
        check("两侧各解出 16 个像素（不是解码失败后的空数组）",
              legacyPixels.count == 16 && newPixels.count == 16,
              "旧 \(legacyPixels.count) / 新 \(newPixels.count)")
        check("两侧各解出 16 个 alpha（同上）",
              legacyAlphas.count == 16 && newAlphas.count == 16,
              "旧 \(legacyAlphas.count) / 新 \(newAlphas.count)")
        check("旧贴图路径（TIFF 往返）与新路径**像素一致**（字节不同是预期的）",
              legacyPixels == newPixels,
              "旧 \(legacy.count) 字节 / 新 \(newData.count) 字节")
        check("旧贴图路径与新路径**alpha 逐像素一致**（透明边缘不变）",
              legacyAlphas == newAlphas,
              "旧 \(legacyAlphas.count) 像素 / 新 \(newAlphas.count) 像素")
        check("新路径确实保留了全透明像素（alpha=0 的那一像素还在）",
              newAlphas.contains(where: { $0 < 0.01 }))
        check("新路径确实保留了半透明像素（没有被打平成全透明/全不透明）",
              newAlphas.contains(where: { $0 > 0.01 && $0 < 0.99 }))
        check("旧贴图路径的 alpha 仍在（透明边缘不变）",
              NSBitmapImageRep(data: legacy)?.hasAlpha == true)
        check("新路径的 alpha 仍在（透明边缘不变）",
              NSBitmapImageRep(data: newData)?.hasAlpha == true)
    } else {
        check("能构造旧贴图路径（TIFF 往返）", false)
    }
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
