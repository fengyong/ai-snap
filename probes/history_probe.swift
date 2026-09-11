import Cocoa

// 截图历史的验证。这类"内存索引 + 磁盘文件"的结构，风险几乎全在**两者不同步**上：
// 淘汰旧文件时漏删、用户手删了文件导致列表里出现点不开的空条目、索引损坏后整个功能挂掉。
// 这些都不会在正常路径上暴露，只能构造出来测。
//
// 链接**真实的** CaptureHistory.swift（不链接 HistoryWindow：它是纯 UI）。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

_ = NSApplication.shared

func makeImage(width: Int, height: Int, shade: UInt8) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for i in 0..<(width * height) {
        buf[i * 4] = shade; buf[i * 4 + 1] = shade; buf[i * 4 + 2] = shade
        buf[i * 4 + 3] = 255
    }
    return ctx.makeImage()!
}

/// 等异步写盘完成（record/remove 都在后台队列上）
@discardableResult
func waitUntil(_ seconds: Double = 8, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("aisnap-history-probe-\(UUID().uuidString)")

func freshHistory() -> CaptureHistory {
    try? FileManager.default.removeItem(at: root)
    return CaptureHistory(directory: root)
}

func fileCount() -> Int {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return files.filter { $0.hasSuffix(".png") }.count
}

// MARK: - 1. 记录与读回

print("=== 1. 记录与读回 ===")
do {
    let history = freshHistory()
    check("开始是空的", history.entries().isEmpty)

    history.record(makeImage(width: 120, height: 80, shade: 40), pixelScale: 2)
    check("记一张后有一条", waitUntil { history.entries().count == 1 },
          "\(history.entries().count) 条")

    let entry = history.entries()[0]
    check("条目尺寸与图一致", entry.pixelWidth == 120 && entry.pixelHeight == 80,
          "\(entry.pixelWidth)×\(entry.pixelHeight)")

    guard let back = history.image(for: entry) else {
        check("能读回原图", false)
        exit(1)
    }
    check("读回的图尺寸一致（PNG 往返无损）",
          back.width == 120 && back.height == 80, "\(back.width)×\(back.height)")

    let thumb = history.thumbnail(for: entry, maxPixel: 40)
    check("缩略图不超过 maxPixel", thumb != nil && max(thumb!.width, thumb!.height) <= 40,
          thumb.map { "\($0.width)×\($0.height)" } ?? "nil")
}

// MARK: - 2. 顺序：新的在前

print("\n=== 2. 新记录排在最前 ===")
do {
    let history = freshHistory()
    for i in 0..<3 {
        history.record(makeImage(width: 50 + i, height: 50, shade: UInt8(20 * (i + 1))), pixelScale: 2)
    }
    check("记了三张", waitUntil { history.entries().count == 3 }, "\(history.entries().count)")
    let entries = history.entries()
    check("按时间倒序（最新的在最前）",
          entries[0].capturedAt >= entries[1].capturedAt
            && entries[1].capturedAt >= entries[2].capturedAt)
    check("第一张的宽度是最后记录的那张（150）",
          entries[0].pixelWidth == 52, "\(entries[0].pixelWidth)")
}

// MARK: - 3. 淘汰旧文件

print("\n=== 3. 超过上限时淘汰最旧的（索引与磁盘一起清）===")
do {
    let history = freshHistory()
    let cap = CaptureHistory.maximumEntries
    let extra = 3
    for i in 0..<(cap + extra) {
        history.record(makeImage(width: 40, height: 30, shade: UInt8(i % 200)), pixelScale: 2)
    }
    check("条目数被压到上限 \(cap)",
          waitUntil { history.entries().count == cap }, "\(history.entries().count)")
    // 写盘是串行的，等最后一个文件也落盘
    check("磁盘上只留下 \(cap) 个 PNG（旧文件真的被删了，不是只从索引里去掉）",
          waitUntil { fileCount() == cap }, "\(fileCount()) 个")

    // 最新那张的原图必须还能读出来
    let newest = history.entries()[0]
    check("保留下来的是最新的那批（最新的能读回）",
          history.image(for: newest) != nil)

    // 最老的那张（按时间排序的最后一条）还在（它是第 cap 张）
    let oldest = history.entries().last!
    check("保留到上限为止的那张仍在", history.image(for: oldest) != nil)
}

// MARK: - 4. 索引跨实例存活

print("\n=== 4. 索引能跨实例读回（换一个实例看同一目录）===")
do {
    let history = freshHistory()
    history.record(makeImage(width: 66, height: 44, shade: 90), pixelScale: 2)
    check("先记一张", waitUntil { history.entries().count == 1 })

    let reopened = CaptureHistory(directory: root)
    check("新实例读到同一条", reopened.entries().count == 1,
          "\(reopened.entries().count)")
    check("新实例能读回原图", reopened.image(for: reopened.entries()[0]) != nil)
}

// MARK: - 5. 用户手删了文件 → 索引要自愈

print("\n=== 5. 文件被外部删掉后，索引不再列出它（不会出现点不开的空条目）===")
do {
    let history = freshHistory()
    history.record(makeImage(width: 30, height: 30, shade: 10), pixelScale: 2)
    history.record(makeImage(width: 31, height: 30, shade: 20), pixelScale: 2)
    check("先记两张", waitUntil { history.entries().count == 2 })

    // 模拟用户到访达里删掉其中一个文件
    let victim = history.entries()[0]
    try? FileManager.default.removeItem(
        at: root.appendingPathComponent(victim.fileName))

    let reopened = CaptureHistory(directory: root)
    check("重开后只剩 1 条（坏条目被丢掉）", reopened.entries().count == 1,
          "\(reopened.entries().count)")
    check("剩下的是文件还在的那条", reopened.entries()[0].id != victim.id)
}

// MARK: - 6. 索引损坏不致命

print("\n=== 6. 索引文件损坏 → 回到空列表，不崩 ===")
do {
    let history = freshHistory()
    history.record(makeImage(width: 30, height: 30, shade: 10), pixelScale: 2)
    check("先记一张", waitUntil { history.entries().count == 1 })

    try? Data("这不是 JSON".utf8).write(to: root.appendingPathComponent("index.json"))
    let reopened = CaptureHistory(directory: root)
    check("损坏的索引被当作空（不崩、不抛）", reopened.entries().isEmpty,
          "\(reopened.entries().count)")

    // 结构对但类型不对
    try? Data("[{\"id\": \"not-a-uuid\"}]".utf8)
        .write(to: root.appendingPathComponent("index.json"))
    let reopened2 = CaptureHistory(directory: root)
    check("结构不匹配也当作空", reopened2.entries().isEmpty)
}

// MARK: - 7. 删除单条 / 清空

print("\n=== 7. 删除与清空 ===")
do {
    let history = freshHistory()
    for _ in 0..<3 { history.record(makeImage(width: 40, height: 30, shade: 60), pixelScale: 2) }
    check("先记三张", waitUntil { history.entries().count == 3 })

    let one = history.entries()[1]
    history.remove(one)
    check("删一条后剩两条", waitUntil { history.entries().count == 2 },
          "\(history.entries().count)")
    check("被删的那条不在列表里",
          !history.entries().contains { $0.id == one.id })
    check("磁盘上那一张也被删了",
          waitUntil { fileCount() == 2 }, "\(fileCount())")
    check("文件确实不在了",
          !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(one.fileName).path))

    history.removeAll()
    check("清空后列表为空", waitUntil { history.entries().isEmpty })
    check("清空后磁盘上没有 PNG 了", waitUntil { fileCount() == 0 }, "\(fileCount())")
}

// MARK: - 8. 记录不存在的目录会自动创建

print("\n=== 8. 首次记录时自动建目录 ===")
do {
    let nested = root.appendingPathComponent("a/b/c")
    try? FileManager.default.removeItem(at: root)
    let history = CaptureHistory(directory: nested)
    history.record(makeImage(width: 20, height: 20, shade: 5), pixelScale: 2)
    check("自动创建了多层目录并写入",
          waitUntil {
              history.entries().count == 1
                && FileManager.default.fileExists(atPath: nested.path)
          })
}

try? FileManager.default.removeItem(at: root)

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
