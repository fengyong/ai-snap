import Cocoa

// OCR 的验证。两处错了都不报错、只给出"看起来对但结果是错的"：
//   1. Vision 归一化框 → 画布矩形的换算（顺手多加一次 Y 翻转，识别框就会整体
//      跑到上下颠倒的位置，而识别到的文字还是对的 —— 很容易误判成"Vision 不准"）
//   2. 阅读顺序（Vision 返回的顺序没有保证，直接拼接会前后跳）
// 所以这里既测纯函数，也**真的跑一次 Vision**：自己画一张有文字的图，
// 看识别框是否落在文字真正所在的位置。
//
// 链接**真实的**全部源文件（除 main.swift）。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

_ = NSApplication.shared

// MARK: - 1. 归一化框 → 画布矩形

print("=== 1. Vision 归一化框 → 画布矩形 ===")
do {
    let rect = TextRecognizer.canvasRect(
        fromNormalized: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        canvasSize: CGSize(width: 200, height: 100))
    check("(0.1,0.2,0.3,0.4) @200×100 → (20,20,60,40)",
          rect == CGRect(x: 20, y: 20, width: 60, height: 40), "\(rect)")

    // 左下角的框应映射到画布左下（y 小），**不做翻转**
    let bottomLeft = TextRecognizer.canvasRect(
        fromNormalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.1),
        canvasSize: CGSize(width: 100, height: 100))
    check("归一化 y=0 的框落在画布底部（y 小 = 下），说明没有多翻一次",
          bottomLeft.minY == 0 && bottomLeft.maxY == 10, "\(bottomLeft)")

    let topRight = TextRecognizer.canvasRect(
        fromNormalized: CGRect(x: 0.5, y: 0.9, width: 0.5, height: 0.1),
        canvasSize: CGSize(width: 100, height: 100))
    check("归一化 y=0.9 的框落在画布顶部（y 大 = 上）",
          topRight.minY == 90, "\(topRight)")
}

// MARK: - 2. 阅读顺序

print("\n=== 2. 阅读顺序 ===")
do {
    func item(_ text: String, x: CGFloat, y: CGFloat,
              w: CGFloat = 100, h: CGFloat = 20) -> RecognizedText {
        RecognizedText(text: text, box: CGRect(x: x, y: y, width: w, height: h))
    }

    // 同一行、x 反序给出 → 应排成从左到右
    let sameLine = [
        item("B", x: 200, y: 100, w: 50),
        item("A", x: 50, y: 100, w: 50),
    ]
    check("同一行按从左到右",
          TextRecognizer.readingOrder(sameLine).map(\.text) == ["A", "B"],
          TextRecognizer.readingOrder(sameLine).map(\.text).joined())

    // 两行、下先给出 → 应排成上到下
    let twoLines = [
        item("第二行", x: 50, y: 20),
        item("第一行", x: 50, y: 120),
    ]
    check("不同行按从上到下",
          TextRecognizer.readingOrder(twoLines).map(\.text) == ["第一行", "第二行"],
          TextRecognizer.readingOrder(twoLines).map(\.text).joined(separator: " → "))

    // 同一行但字高不齐（中心相差在容差内）→ 仍算同一行，按 x 排
    let uneven = [
        item("右", x: 200, y: 100, w: 50, h: 20),
        item("左小字", x: 50, y: 103, w: 50, h: 8),   // 中心差 3，容差 = min(20,8)*0.5 = 4
    ]
    check("同一行高低不齐时不被拆成两行",
          TextRecognizer.readingOrder(uneven).map(\.text) == ["左小字", "右"],
          TextRecognizer.readingOrder(uneven).map(\.text).joined())

    check("拼接按阅读顺序、每段一行",
          TextRecognizer.joinedText(twoLines) == "第一行\n第二行",
          TextRecognizer.joinedText(twoLines).debugDescription)

    check("空输入不崩", TextRecognizer.joinedText([]).isEmpty)
    check("单条输入原样返回",
          TextRecognizer.readingOrder([item("只有一条", x: 0, y: 0)]).count == 1)
}

// MARK: - 3. 真的跑一次 Vision

print("\n=== 3. 端到端：自己画一张有文字的图，跑真实识别 ===")
do {
    // 上半部分写一行大字、左下方写一行小字，位置都是已知的
    let canvasSize = NSSize(width: 500, height: 260)
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    let big: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]
    let small: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24),
        .foregroundColor: NSColor.black,
    ]
    // NSImage 的绘制坐标是左下原点：y=180 在上半部，y=40 在下半部
    ("AISnap 2026" as NSString).draw(at: NSPoint(x: 40, y: 180), withAttributes: big)
    ("bottom line" as NSString).draw(at: NSPoint(x: 40, y: 40), withAttributes: small)
    image.unlockFocus()

    var box = CGRect.zero
    image.cgImage(forProposedRect: &box, context: nil, hints: nil)
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    print("     测试图 \(cg.width)×\(cg.height) 像素")

    var items: [RecognizedText] = []
    var done = false
    TextRecognizer.recognize(in: cg, canvasSize: canvasSize) { found in
        items = found
        done = true
    }
    // 等后台识别完成（最多 20 秒）
    let deadline = Date().addingTimeInterval(20)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    check("识别回调回来了（没有死等超时）", done)
    check("识别到至少两段文字", items.count >= 2, "\(items.count) 段")

    let joined = TextRecognizer.joinedText(items)
    print("     识别结果：\(joined.replacingOccurrences(of: "\n", with: " / "))")
    check("认出了上半部那行（含 AISnap）", joined.contains("AISnap"))
    check("认出了下半部那行（含 bottom）",
          joined.lowercased().contains("bottom"))

    guard let upper = items.first(where: { $0.text.contains("AISnap") }),
          let lower = items.first(where: { $0.text.lowercased().contains("bottom") })
    else {
        print("     ⚠️ 找不到用于定位的两段，跳过落点断言")
        print("\n通过 \(passed) 项，失败 \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }

    // ★ 落点：上半部那行必须落在画布上半部（y > 一半）。
    // 多加一次 Y 翻转的话，这两条会正好互换。
    check("上半部那行的框落在画布上半部（Y 翻转错了会落到下半部）",
          upper.box.midY > canvasSize.height / 2,
          String(format: "midY = %.0f / %.0f", upper.box.midY, canvasSize.height))
    check("下半部那行的框落在画布下半部",
          lower.box.midY < canvasSize.height / 2,
          String(format: "midY = %.0f / %.0f", lower.box.midY, canvasSize.height))

    // 横向：文字从 x=40 起，框的左边界应落在 40 附近（Vision 会留一点边距）
    check("上半部那行的框左边界在 40 附近",
          upper.box.minX > 20 && upper.box.minX < 70,
          String(format: "minX = %.0f", upper.box.minX))
    check("框不出画布范围",
          upper.box.minX >= 0 && upper.box.maxX <= canvasSize.width
            && upper.box.minY >= 0 && upper.box.maxY <= canvasSize.height,
          "\(upper.box)")

    // 阅读顺序：上半部那行应排在前面
    let order = TextRecognizer.readingOrder(items)
    check("阅读顺序把上半部那行排在前面",
          order.first?.text.contains("AISnap") == true,
          order.map { $0.text.prefix(12) }.joined(separator: " → "))

    // 识别框高度应大致等于字号（40pt 的框不该只有 5 点高，也不该有 200 点高）
    check("识别框高度与字号量级相符（30…80 点）",
          upper.box.height > 30 && upper.box.height < 80,
          String(format: "%.0f 点", upper.box.height))
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
