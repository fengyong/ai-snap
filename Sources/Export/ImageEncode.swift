import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 导出编码：按保存面板选定的格式编码出 Data。
///
/// 从 `AnnotationWindow.pngData` 抽出来的通用层 —— PNG 编码逻辑只有一份
/// （「不走 tiffRepresentation 中转」的理由逐字保留在本文件 `png(from:)` 的文档里）。
///
/// 2026-11-11（O8）：`AnnotationWindow.pngData` 这个转发层已删（它只做一次转调），
/// 截图历史与贴图窗也改调这里 —— 同一语义的编码从此只有本文件一处实现。
enum ImageEncode {

    /// 保存面板支持的格式。顺序即面板下拉顺序，png 在前 = 默认格式（行为不变）。
    static let supportedTypes: [UTType] = [.png, .jpeg, .heic]

    /// 按目标 URL 的扩展名编码；认不出的扩展名按 PNG（保存面板已经限制了可选项，
    /// 走到 default 的只有手工改过文件名的情况）。
    static func data(from image: NSImage, url: URL) -> Data? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return lossy(from: image, fileType: .jpeg, uti: "public.jpeg", quality: 0.9)
        case "heic":
            // NSBitmapImageRep.FileType 没有 .heic —— HEIC 只能走 ImageIO
            return viaImageIO(image, uti: "public.heic",
                              properties: [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        default:
            return png(from: image)
        }
    }

    /// PNG（无损）。
    ///
    /// **不走 `tiffRepresentation` 中转**：那条路会先把整幅图编码成 TIFF、再解码回
    /// `NSBitmapImageRep`，等于为了拿到一个位图白白搬运一遍全图数据（Retina 全屏 60MB 级），
    /// 而且这一步跑在主线程（⌘S / ⌘C 会卡住）。
    ///
    /// 复合图本身就是 `NSBitmapImageRep`（见 `AnnotationView.compositeImage`），
    /// 直接拿它编码即可；只有"没有位图 rep"的图（例如纯 PDF 矢量 rep）才退回 ImageIO。
    ///
    /// 探针在 `export_encode_probe` 里验证「编码出来的像素与原图逐位一致」——
    /// 换编码器最容易悄悄改变颜色/透明度，而那种错用户只会觉得"存出来的图有点不对"。
    /// 2026-11-11（O8）：原先那段文档挂在 `AnnotationWindow.pngData` 上，那个转发层
    /// 已删，理由随之搬到这里 —— 理由真正约束的代码就是本方法。
    static func png(from image: NSImage) -> Data? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           let data = rep.representation(using: .png, properties: [:]) {
            return data
        }
        return viaImageIO(image, uti: "public.png", properties: nil)
    }

    /// PNG（无损）—— CGImage 入口。
    ///
    /// 与 NSImage 入口**产出同一份字节**（2026-11-11 实测：两条路最终都落到
    /// 「NSBitmapImageRep → representation(using: .png, properties: [:])」，
    /// 对同一张图字节逐位相同）。
    ///
    /// 为什么要有两个入口：截图历史拿到的就是 CGImage，贴图窗拿到的就是 NSImage ——
    /// 同一语义曾有两份独立实现，编码参数（压缩级别、色彩空间）将来要调时
    /// 改一处漏一处。
    static func png(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// JPEG（有损，固定 0.9 —— 与大多数工具的"高质量"档相当）。
    /// NSBitmapImageRep 路失败时退 ImageIO，再失败返回 nil，由调用方给
    /// 「编码失败」提示 —— 用户至少知道没存上，而不是得到一个 0 字节文件。
    private static func lossy(from image: NSImage,
                              fileType: NSBitmapImageRep.FileType,
                              uti: String,
                              quality: Double) -> Data? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           let data = rep.representation(using: fileType,
                                         properties: [.compressionFactor: quality]) {
            return data
        }
        return viaImageIO(image, uti: uti,
                          properties: [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    }

    /// ImageIO 兜底路径（与 PNG 原实现里那段一致，参数化的 UTI / 压缩属性）。
    private static func viaImageIO(_ image: NSImage, uti: String,
                                   properties: CFDictionary?) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let buffer = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(buffer, uti as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, properties)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
