import Cocoa
import ImageIO

/// 截图历史。
///
/// 记录**每一次截图的原图**（含用户后来没有保存的那些）。存原图而不是存最终合成图：
/// 这样"重新编辑"能从干净的一张图开始，而不是从一张已经画满箭头的图上再画一遍。
///
/// 存储：`~/Library/Application Support/AISnap/History/`
/// - 每张截图一个 PNG，文件名带时间戳
/// - `index.json` 是索引（时间、尺寸、文件名）
///
/// 索引里的 `fileName` 与实际文件可能不一致（用户手动删过、或写盘写到一半断了），
/// 所以加载时会按"文件是否真的在"过滤一遍 —— 否则历史列表里会出现点不开的空条目。
final class CaptureHistory {

    struct Entry: Codable, Equatable {
        let id: UUID
        let capturedAt: Date
        let pixelWidth: Int
        let pixelHeight: Int
        let fileName: String
        /// 「图像像素 ÷ 逻辑点」的倍率。**可选**是为了兼容加入本字段之前写入的
        /// index.json —— 改成非可选会让老索引整个解码失败，那等于把用户的历史清空。
        let pixelScale: CGFloat?
    }

    /// 最多保留多少张。整屏 PNG 每张 1–5MB，不设上限会把磁盘慢慢吃掉。
    /// 这个数字也在帮助文案里对用户说明 —— 悄悄丢用户的东西比占地更糟。
    static let maximumEntries = 30

    static let shared = CaptureHistory(directory: defaultDirectory())

    static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("AISnap/History", isDirectory: true)
    }

    private let directory: URL
    /// 串行队列：索引的读改写、文件写入、淘汰旧文件都排成一队，不并发。
    /// 用 `.utility` 是因为"记录一张截图"对用户而言不是急事 —— 它不该抢
    /// 标注窗口打开的响应速度。
    private let queue = DispatchQueue(label: "com.aisnap.history", qos: .utility)
    private let lock = NSLock()
    private var index: [Entry] = []

    init(directory: URL) {
        self.directory = directory
        loadIndex()
    }

    // MARK: - 读

    /// 已记录的条目，新到旧。
    func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func image(for entry: Entry) -> CGImage? {
        Self.loadImage(at: directory.appendingPathComponent(entry.fileName), maxPixel: nil)
    }

    /// 缩略图。用 `CGImageSourceCreateThumbnailAtIndex` 而不是先解码整图再缩 ——
    /// 历史列表一次要显示几十张整屏截图（每张几 MB），全解码会明显卡顿。
    func thumbnail(for entry: Entry, maxPixel: Int = 320) -> CGImage? {
        Self.loadImage(at: directory.appendingPathComponent(entry.fileName),
                       maxPixel: maxPixel)
    }

    private static func loadImage(at url: URL, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let maxPixel = maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return thumb
            }
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - 写

    /// 记录一张截图。**异步**：PNG 编码加写盘在整屏尺寸下要几百毫秒，
    /// 放主线程会让标注窗口打开时明显一顿。
    ///
    /// `pixelScale` 是捕获方实测反推的倍率，随条目一起存下来 ——
    /// 否则从历史里「重新编辑」时得重新猜一个倍率，猜错的后果是画布尺寸与实际
    /// 像素不符（导出尺寸跟着错），而这种错要拿尺子量才发现。
    func record(_ image: CGImage, pixelScale: CGFloat, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let data = Self.pngData(from: image) else { return }

            let now = Date()
            let entry = Entry(
                id: UUID(),
                capturedAt: now,
                pixelWidth: image.width,
                pixelHeight: image.height,
                fileName: "\(Int(now.timeIntervalSince1970 * 1000))-"
                    + "\(UUID().uuidString.prefix(8)).png",
                pixelScale: pixelScale
            )

            let manager = FileManager.default
            try? manager.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let url = self.directory.appendingPathComponent(entry.fileName)
            // 原子写：非原子写在写盘中途崩溃会留下"文件存在但内容不全"的半张图，
            // 而索引仍认为它有效 —— 表现是历史列表里出现一张显示不出来的破图
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }

            self.lock.lock()
            self.index.insert(entry, at: 0)
            var overflow: [Entry] = []
            if self.index.count > Self.maximumEntries {
                overflow = Array(self.index[Self.maximumEntries...])
                self.index = Array(self.index.prefix(Self.maximumEntries))
            }
            self.lock.unlock()

            for old in overflow {
                try? manager.removeItem(
                    at: self.directory.appendingPathComponent(old.fileName))
            }
            self.saveIndex()

            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    func remove(_ entry: Entry, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(
                at: self.directory.appendingPathComponent(entry.fileName))
            self.lock.lock()
            self.index.removeAll { $0.id == entry.id }
            self.lock.unlock()
            self.saveIndex()
            if let completion = completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    func removeAll(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.directory)
            self.lock.lock()
            self.index = []
            self.lock.unlock()
            if let completion = completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: - 索引落盘

    private func loadIndex() {
        let url = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return
        }
        // 丢掉"索引里有、文件却不在"的条目
        let existing = decoded.filter {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0.fileName).path)
        }
        lock.lock()
        index = existing
        lock.unlock()
    }

    private func saveIndex() {
        let snapshot = entries()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
