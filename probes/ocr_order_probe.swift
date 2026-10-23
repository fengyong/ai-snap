// OCR 结果面板：显示顺序 ↔ 区间 ↔ 识别框 必须同源。
//
// 背景（P0-3）：面板里三样东西依赖顺序 ——
//   · blockRanges：每段在文本里的区间
//   · displayText：显示与复制的全文
//   · items：区间 → 识别框的映射
// 原来 blockRanges 按 Vision 的**原始数组序**建立，而显示的文本走
// TextRecognizer.joinedText（内部按阅读顺序重排）—— 两者不同源。
// 而 Vision 返回顺序 ≠ 阅读顺序是常态，于是「选中第 N 段 → 高亮第 N 个框」
// 指向了另一段的框：面板存在的意义（让人看出这段文字来自图像哪里）被反转了。
//
// 这里钉住的核心不变式：**面板显示的第 i 段，其区间与识别框必须是同一段**。
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

func item(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 50, _ h: CGFloat = 20)
    -> RecognizedText {
    RecognizedText(text: text, box: CGRect(x: x, y: y, width: w, height: h))
}

func findTextView(_ v: NSView) -> NSTextView? {
    if let t = v as? NSTextView { return t }
    for sub in v.subviews { if let t = findTextView(sub) { return t } }
    return nil
}

/// 在面板里选中一个区间，并手动触发选择变化回调（探针没有事件循环）
func select(_ textView: NSTextView, _ range: NSRange) {
    textView.selectedRange = range
    (textView.delegate as? NSTextViewDelegate)?
        .textViewDidChangeSelection?(Notification(name: NSTextView.didChangeSelectionNotification,
                                                 object: textView))
}

/// 第 i 段在文本里的区间（UTF-16 长度 + 段间 1 个换行）
func blockRange(_ items: [RecognizedText], _ i: Int) -> NSRange {
    var location = 0
    for j in 0..<i { location += (items[j].text as NSString).length + 1 }
    return NSRange(location: location, length: (items[i].text as NSString).length)
}

print("=== 1. 同一行、Vision 先返回右边的：选中的段必须高亮它自己的框 ===\n")
do {
    // Vision 原始顺序：右边在前
    let items = [
        item("RIGHT", 200, 100),
        item("LEFT", 20, 100),
    ]
    let panel = OCRResultWindow(items: items)
    var highlighted: [CGRect] = []
    panel.onHighlightChanged = { highlighted = $0 }
    guard let textView = panel.contentView.flatMap({ findTextView($0) }) else {
        check("面板里有可选文本视图", false); exit(1)
    }

    let displayed = textView.string
    check("显示顺序是阅读顺序（LEFT 在前）",
          displayed == "LEFT\nRIGHT", "\(displayed.debugDescription)")

    // 面板内部排好序之后，第 0 段是 LEFT
    let ordered = TextRecognizer.readingOrder(items)
    check("面板显示的第 0 段就是 LEFT", ordered[0].text == "LEFT", ordered[0].text)

    // 选第 0 段 → 高亮的必须是 LEFT 的框（x=20），而不是 RIGHT 的
    select(textView, blockRange(ordered, 0))
    check("选第 1 段 → 高亮的是它自己的框",
          highlighted == [ordered[0].box],
          "高亮 \(highlighted.map { "x=\($0.minX)" }) 期望 x=\(ordered[0].box.minX)")

    // 选第 1 段 → 高亮 RIGHT 的框
    select(textView, blockRange(ordered, 1))
    check("选第 2 段 → 高亮的是它自己的框",
          highlighted == [ordered[1].box],
          "高亮 \(highlighted.map { "x=\($0.minX)" }) 期望 x=\(ordered[1].box.minX)")
}

print("\n=== 2. 多行乱序：上下与左右都要对 ===\n")
do {
    // Vision 给的顺序：右下 → 左上 → 右下 → 左上
    let items = [
        item("D", 200, 20),
        item("A", 20, 200),
        item("C", 20, 20),
        item("B", 200, 200),
    ]
    let panel = OCRResultWindow(items: items)
    var highlighted: [CGRect] = []
    panel.onHighlightChanged = { highlighted = $0 }
    guard let textView = panel.contentView.flatMap({ findTextView($0) }) else {
        check("面板里有可选文本视图", false); exit(1)
    }
    let ordered = TextRecognizer.readingOrder(items)
    check("阅读顺序 = A B C D", ordered.map(\.text) == ["A", "B", "C", "D"],
          ordered.map(\.text).joined(separator: " "))
    check("显示文本与阅读顺序一致",
          textView.string == ordered.map(\.text).joined(separator: "\n"),
          textView.string.debugDescription)

    // 逐段核对：每一段的区间取出来的文字 == 该段文本，高亮的框 == 该段框
    var allAligned = true
    var detail = ""
    for i in 0..<ordered.count {
        let range = blockRange(ordered, i)
        let text = (textView.string as NSString).substring(with: range)
        select(textView, range)
        if text != ordered[i].text || highlighted != [ordered[i].box] {
            allAligned = false
            detail = "第 \(i) 段：文字 \(text.debugDescription)/\(ordered[i].text.debugDescription)，" +
                     "高亮 \(highlighted.count) 个"
            break
        }
    }
    check("逐段核对：区间文字与识别框全部对齐", allAligned, detail)
}

print("\n=== 3. 复制全部 = 面板显示的全文（不是另一个排序口径）===\n")
do {
    let items = [item("B", 200, 100), item("A", 20, 100)]
    let panel = OCRResultWindow(items: items)
    check("allText == 显示文本", panel.allText == TextRecognizer.readingOrder(items)
            .map(\.text).joined(separator: "\n"), panel.allText.debugDescription)
}

print("\n=== 4. emoji 段（UTF-16 长度 ≠ 字素簇数）仍然对齐 ===\n")
do {
    // 带 emoji 的那段放在**上面**（y 更大）→ 阅读顺序里它排第一，
    // 于是「区间按 UTF-16 算」这件事正好作用在第一个块上。
    let items = [
        item("第二段 👍 收货人", 10, 200),
        item("第一段 订单号 A123", 10, 150),
    ]
    let panel = OCRResultWindow(items: items)
    var highlighted: [CGRect] = []
    panel.onHighlightChanged = { highlighted = $0 }
    guard let textView = panel.contentView.flatMap({ findTextView($0) }) else {
        check("面板里有可选文本视图", false); exit(1)
    }
    let ordered = TextRecognizer.readingOrder(items)
    check("带 emoji 的段排在前面（y 更大 = 更靠上）",
          ordered[0].text.hasPrefix("第二段"), ordered[0].text)
    // 选带 emoji 的那一段：区间按 UTF-16 算，不能错位
    select(textView, blockRange(ordered, 0))
    check("带 emoji 段：文字与框都对齐",
          (textView.string as NSString).substring(with: blockRange(ordered, 0)) == ordered[0].text
          && highlighted == [ordered[0].box],
          "高亮 \(highlighted.count) 个")
    // 再选后面那段：emoji 占 2 个 UTF-16 单元，若按字素簇算这段就会整体错位
    select(textView, blockRange(ordered, 1))
    check("emoji 之后的段没有错位",
          (textView.string as NSString).substring(with: blockRange(ordered, 1)) == ordered[1].text
          && highlighted == [ordered[1].box],
          "高亮 \(highlighted.count) 个")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
