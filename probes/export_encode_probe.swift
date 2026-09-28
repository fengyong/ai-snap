// 导出编码探针：验证 ImageEncode 的格式分发与数据合法性。
//
// PNG 沿用原 AnnotationWindow.pngData 的逐位一致断言思路；JPEG/HEIC 是有损格式，
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
    // 与 AnnotationWindow.pngData 的薄包装一致（同一实现，探针经实例方法再验一次）
    // —— 这里只验分发，逐位一致断言在 master_parity_probe 的既有用例里。
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

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
