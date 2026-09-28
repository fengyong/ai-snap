import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 导出编码：按保存面板选定的格式编码出 Data。
///
/// 从 `AnnotationWindow.pngData` 抽出来的通用层 —— PNG 编码逻辑只有一份
/// （「不走 tiffRepresentation 中转」的理由见 `AnnotationWindow.pngData` 的文档，
/// 这里逐字保留），JPEG / HEIC 是它的有损兄弟。
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

    /// PNG（无损）。逻辑与原 `AnnotationWindow.pngData` 一致；探针通过那个实例方法
    /// 验证「编码出来的像素与原图逐位一致」，走的正是这里。
    static func png(from image: NSImage) -> Data? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           let data = rep.representation(using: .png, properties: [:]) {
            return data
        }
        return viaImageIO(image, uti: "public.png", properties: nil)
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
