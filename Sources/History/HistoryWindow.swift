import Cocoa

/// 截图历史浏览窗口。
///
/// 列表形式（不是网格）：每条要同时给出时间、尺寸和几个操作按钮，
/// 网格里塞这些字会挤成一团。行高固定，用绝对坐标排布 —— 与项目其它地方一致。
final class HistoryWindow: NSWindow {

    /// 点「打开」时回调：把原图交给 AppDelegate 去开标注窗口（即"重新编辑"）。
    /// 一并带上记录时存下的像素倍率，画布尺寸才不会猜错。
    var onOpen: ((CapturedImage) -> Void)?

    private let history: CaptureHistory
    private let scrollView = NSScrollView()
    private let listView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [NSView] = []
    /// 当前列表对应的条目快照。按钮的 tag 是这张表里的下标 ——
    /// 用"最新的 entries()"去解释 tag 是不对的：删除一张之后下标就会整体错位，
    /// 表现是"点删除却删掉了下一张"。
    private var currentEntries: [CaptureHistory.Entry] = []

    private let rowHeight: CGFloat = 116
    private let thumbBox = NSSize(width: 168, height: 96)

    init(history: CaptureHistory = .shared) {
        self.history = history
        let size = NSSize(width: 640, height: 560)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "AISnap - 截图历史"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 520, height: 320)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        contentView = container

        // ── 顶部条 ──
        let header = NSView(frame: NSRect(x: 0, y: size.height - 40, width: size.width, height: 40))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        header.autoresizingMask = [.width, .minYMargin]

        let hint = NSTextField(labelWithString:
            "最近的截图都留在这里（含没有保存的）。最多保留 \(CaptureHistory.maximumEntries) 张。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 14, y: 13, width: 400, height: 16)
        header.addSubview(hint)

        let clearBtn = NSButton(frame: NSRect(x: size.width - 96, y: 7, width: 84, height: 26))
        clearBtn.title = "清空历史"
        clearBtn.font = NSFont.systemFont(ofSize: 12)
        clearBtn.bezelStyle = .rounded
        clearBtn.target = self
        clearBtn.action = #selector(clearAll)
        clearBtn.autoresizingMask = [.minXMargin]
        header.addSubview(clearBtn)
        container.addSubview(header)

        let separator = NSBox(frame: NSRect(x: 0, y: size.height - 41, width: size.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        container.addSubview(separator)

        // ── 列表 ──
        scrollView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - 41)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor

        listView.frame = NSRect(x: 0, y: 0, width: size.width, height: 0)
        scrollView.documentView = listView
        container.addSubview(scrollView)

        emptyLabel.stringValue = "还没有截图记录。\n截一张图就会出现在这里。"
        emptyLabel.alignment = .center
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.frame = NSRect(x: 0, y: 0, width: size.width, height: 60)
        emptyLabel.autoresizingMask = []
        container.addSubview(emptyLabel)

        reload()
    }

    override var canBecomeKey: Bool { true }

    // MARK: - 列表刷新

    func reload() {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        let entries = history.entries()
        currentEntries = entries
        emptyLabel.isHidden = !entries.isEmpty
        emptyLabel.frame = NSRect(x: 0, y: scrollView.frame.height / 2 - 30,
                                  width: scrollView.frame.width, height: 60)

        var y = CGFloat(entries.count) * rowHeight
        for entry in entries {
            y -= rowHeight
            let row = makeRow(for: entry, width: scrollView.frame.width, top: y)
            listView.addSubview(row)
            rows.append(row)
        }
        listView.frame = NSRect(x: 0, y: 0, width: scrollView.frame.width,
                                height: max(CGFloat(entries.count) * rowHeight, 1))
    }

    private func makeRow(for entry: CaptureHistory.Entry, width: CGFloat,
                         top: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: top, width: width, height: rowHeight))
        row.autoresizingMask = [.width]

        // 缩略图
        let thumbRect = NSRect(x: 14, y: (rowHeight - thumbBox.height) / 2,
                               width: thumbBox.width, height: thumbBox.height)
        let imageView = NSImageView(frame: thumbRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.layer?.borderWidth = 1
        imageView.layer?.cornerRadius = 4
        if let cg = history.thumbnail(for: entry) {
            imageView.image = NSImage(cgImage: cg,
                                      size: NSSize(width: cg.width, height: cg.height))
        }
        row.addSubview(imageView)

        // 两行说明：时间 / 像素尺寸
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm:ss"
        let timeText = formatter.string(from: entry.capturedAt)
        let timeLabel = NSTextField(labelWithString: timeText)
        timeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        timeLabel.frame = NSRect(x: 198, y: rowHeight - 46, width: 260, height: 18)
        row.addSubview(timeLabel)

        let sizeLabel = NSTextField(labelWithString:
            "\(entry.pixelWidth) × \(entry.pixelHeight) 像素")
        sizeLabel.font = NSFont.systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.frame = NSRect(x: 198, y: rowHeight - 66, width: 260, height: 16)
        row.addSubview(sizeLabel)

        // 按钮：打开（重新编辑）最常用，放最左
        let actions: [(String, Selector)] = [
            ("打开", #selector(openRow(_:))),
            ("复制", #selector(copyRow(_:))),
            ("显示", #selector(revealRow(_:))),
            ("删除", #selector(deleteRow(_:))),
        ]
        var x: CGFloat = 198
        for (title, action) in actions {
            let btn = NSButton(frame: NSRect(x: x, y: rowHeight - 108,
                                             width: title.count > 1 ? 52 : 44, height: 24))
            btn.title = title
            btn.font = NSFont.systemFont(ofSize: 11)
            btn.bezelStyle = .rounded
            btn.toolTip = tooltip(for: title)
            btn.target = self
            btn.action = action
            btn.tag = entryTag(entry)
            row.addSubview(btn)
            x += btn.frame.width + 6
        }

        let separator = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        row.addSubview(separator)

        return row
    }

    private func tooltip(for title: String) -> String {
        switch title {
        case "打开": return "在这个截图上继续标注（重新编辑）"
        case "复制": return "复制到剪贴板"
        case "显示": return "在访达中显示文件"
        default:     return "从历史里删除这一张"
        }
    }

    // MARK: - 按钮 action 与「tag → 条目」的映射
    //
    // NSButton 的 tag 是 Int，放不下 UUID，所以按钮的 tag 记的是条目在
    // `currentEntries`（本屏列表的快照）里的下标。
    private func entryTag(_ entry: CaptureHistory.Entry) -> Int {
        currentEntries.firstIndex(of: entry) ?? 0
    }

    private func entry(for sender: NSButton) -> CaptureHistory.Entry? {
        guard sender.tag >= 0, sender.tag < currentEntries.count else { return nil }
        return currentEntries[sender.tag]
    }

    @objc private func openRow(_ sender: NSButton) {
        guard let entry = entry(for: sender),
              let image = history.image(for: entry) else {
            NSSound.beep()
            return
        }
        // 加入 pixelScale 字段之前记录的老条目没有这个值，只能按当前屏幕倍率兜底。
        // 只影响"从历史重新编辑"时的画布尺寸，导出的像素内容不受影响。
        let scale = entry.pixelScale ?? NSScreen.main?.backingScaleFactor ?? 2
        onOpen?(CapturedImage(image: image, pixelScale: scale, anchorRect: nil))
        orderOut(nil)
    }

    @objc private func copyRow(_ sender: NSButton) {
        guard let entry = entry(for: sender),
              let image = history.image(for: entry) else {
            NSSound.beep()
            return
        }
        // 像素尺寸 ≠ 点尺寸：Retina 截图（pixelScale == 2）如果按"像素当点"构造
        // NSImage，粘贴到按点解释的应用里会放大一倍。按条目的 pixelScale 折回逻辑尺寸
        // —— 与主标注窗口的复制路径（compositeImage 出来的就是点尺寸）保持一致。
        // 老条目没有 pixelScale，按当前屏倍率兜底。
        let scale = entry.pixelScale ?? NSScreen.main?.backingScaleFactor ?? 2
        let nsImage = NSImage(cgImage: image,
                              size: NSSize(width: CGFloat(image.width) / scale,
                                           height: CGFloat(image.height) / scale))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    @objc private func revealRow(_ sender: NSButton) {
        guard let entry = entry(for: sender) else { return }
        let url = CaptureHistory.defaultDirectory()
            .appendingPathComponent(entry.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func deleteRow(_ sender: NSButton) {
        guard let entry = entry(for: sender) else { return }
        history.remove(entry) { [weak self] in
            self?.reload()
        }
    }

    @objc private func clearAll() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清空截图历史？"
        alert.informativeText = "这会删除历史里保存的全部截图（一共 \(history.entries().count) 张）。\n"
            + "已经保存到别处的文件不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.removeAll { [weak self] in
            self?.reload()
        }
    }
}
