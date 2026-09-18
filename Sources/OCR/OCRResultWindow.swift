import Cocoa

/// OCR 结果面板：把识别到的每一段按阅读顺序列成多行，让用户自己挑要哪几段。
///
/// 为什么需要它：识别完直接把整段文字塞进剪贴板，用户没有选择权 ——
/// 只想要里面一个订单号，粘出来却是一整屏。
///
/// 选区与画布联动：选中的行对应的识别框会在图上高亮。
/// 这样既能看到"我要的这几段在图上哪儿"，也能反过来确认"这段字是从哪儿读出来的"。
final class OCRResultWindow: NSPanel, NSTextViewDelegate, NSWindowDelegate {

    /// 选区变化时回调，参数是当前应高亮的识别框（**空选区 = 全部**）
    var onHighlightChanged: (([CGRect]) -> Void)?
    /// 复制成功后的提示（交给标注窗口的 HUD，面板不自己造提示，免得两个地方各闪一下）
    var onCopied: ((String) -> Void)?
    /// 面板关闭时回调（标注窗口用它清掉画布上的识别框）
    var onClose: (() -> Void)?

    private let items: [RecognizedText]

    /// 每段在文本里的 UTF-16 区间。
    ///
    /// **必须按 UTF-16 算**：Swift 的 `String.count` 是字素簇，
    /// 而 `NSTextView.selectedRange()` 用的是 UTF-16 偏移 ——
    /// 中文/emoji 下两者不相等，混用会让选区落到错误的段上。
    private let blockRanges: [NSRange]

    private let textView = NSTextView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private var copySelectionButton: NSButton!

    init(items: [RecognizedText]) {
        self.items = items

        var ranges: [NSRange] = []
        var location = 0
        for item in items {
            let length = (item.text as NSString).length
            ranges.append(NSRange(location: location, length: length))
            location += length + 1          // +1 是 joinedText 里的 "\n"
        }
        self.blockRanges = ranges

        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered,
                   defer: false)

        title = "识别结果"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        // 面板必须能成为 key，否则文本框选不了字、⌘C 也送不到这儿
        becomesKeyOnlyIfNeeded = false
        delegate = self
        buildUI()
    }

    // MARK: - 对外

    /// 当前选中的文字；没有选区时返回 nil
    var selectedText: String? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    var allText: String { textView.string }

    /// 有选区就复制选区、否则复制全部。返回复制到的内容（空则返回 nil）。
    /// 供本面板的按钮与标注窗口的 ⌘C 共用。
    @discardableResult
    func copySelectionOrAllToPasteboard() -> String? {
        let text = selectedText ?? allText
        guard !text.isEmpty else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }

    /// 只复制全部（「复制全部」按钮用；不想被当前选区影响）
    @discardableResult
    func copyAllToPasteboard() -> String? {
        let text = allText
        guard !text.isEmpty else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = contentView else { return }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = TextRecognizer.joinedText(items)
        textView.delegate = self
        scroll.documentView = textView

        copySelectionButton = NSButton(title: "复制选中", target: self,
                                       action: #selector(copySelectionAction))
        let copyAllButton = NSButton(title: "复制全部", target: self,
                                     action: #selector(copyAllAction))
        let closeButton = NSButton(title: "关闭", target: self,
                                   action: #selector(closeAction))
        for button in [copySelectionButton!, copyAllButton, closeButton] {
            button.bezelStyle = .rounded
        }

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "共 \(items.count) 段　拖动鼠标可只选其中几段，⌘C 复制"

        let buttons = NSStackView(views: [copySelectionButton, copyAllButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(statusLabel)
        content.addSubview(buttons)

        // 纵向约束必须**四边闭合**（top → scroll → status → buttons → bottom），
        // 少一条就会让 fittingSize 退化、窗口被压成一条缝（偏好设置窗口踩过）。
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        updateButtons()
    }

    // MARK: - 选区联动

    func textViewDidChangeSelection(_ notification: Notification) {
        updateButtons()

        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            statusLabel.stringValue = "共 \(items.count) 段　拖动鼠标可只选其中几段，⌘C 复制"
            onHighlightChanged?(items.map(\.box))        // 空选区 = 全部高亮
            return
        }

        let touched = blockRanges.enumerated()
            .filter { NSIntersectionRange($0.element, selection).length > 0 }
            .map(\.offset)
        statusLabel.stringValue = "已选 \(touched.count) 段　⌘C 复制"
        onHighlightChanged?(touched.map { items[$0].box })
    }

    private func updateButtons() {
        copySelectionButton?.isEnabled = textView.selectedRange().length > 0
    }

    // MARK: - Actions

    @objc private func copySelectionAction() {
        guard let text = copySelectionOrAllToPasteboard() else { NSSound.beep(); return }
        onCopied?("已复制选中文字（\(text.count) 字）")
    }

    @objc private func copyAllAction() {
        guard let text = copyAllToPasteboard() else { NSSound.beep(); return }
        onCopied?("已复制全部 \(items.count) 段（\(text.count) 字）")
    }

    @objc private func closeAction() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
