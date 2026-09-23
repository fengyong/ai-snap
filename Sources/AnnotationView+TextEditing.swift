import Cocoa

// MARK: - Text Editing

/// 文字标注的行内编辑。
///
/// 做法：在画布上叠一个 `NSTextField`，位置与字号对齐到目标文字上，
/// 让它成为第一响应者；提交/取消后把结果写回 `TextShape` 并移除输入框。
///
/// 为什么不直接在画布上处理键盘输入：那要自己实现光标、选区、输入法（IME，
/// 中文输入必需）—— 而这正是 `NSTextField` 已经做好的事。
/// 自己实现 IME 是这类工具里最容易被低估的一块工作量。
extension AnnotationView {

    /// 开始编辑某条文字标注。会先结束上一次未提交的编辑。
    func beginEditingText(_ shape: TextShape, key: UInt32) {
        endTextEditing(commit: true)

        // 输入框比文字本身宽一些：正在打字时字会变长，框太紧会频繁挪动
        let size = shape.contentSize
        let fieldWidth = max(size.width + 120, 160)
        let fieldHeight = max(size.height, shape.fontSize + 12)

        let field = NSTextField(frame: NSRect(x: shape.center.x - fieldWidth / 2,
                                              y: shape.center.y - fieldHeight / 2,
                                              width: fieldWidth,
                                              height: fieldHeight))
        field.font = shape.font
        field.textColor = shape.color
        field.alignment = .center
        field.stringValue = shape.text
        field.placeholderString = "输入文字，回车确认，Esc 取消"
        field.isBordered = false
        field.drawsBackground = true
        // 半透明深底：文字是浅色时压在浅色截图上会看不清，输入过程中更需要可读
        field.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)

        window?.makeFirstResponder(field)
        textEditingField = field
        textEditingKey = key
        textEditingOriginalText = shape.text
    }

    /// 结束编辑。`commit == false` 或内容为空时按情况回滚。
    func endTextEditing(commit: Bool) {
        guard let field = textEditingField, let key = textEditingKey else { return }

        let newText = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = textEditingOriginalText

        // 先清状态再收尾，避免 removeFromSuperview 触发的回调重入
        textEditingField = nil
        textEditingKey = nil
        textEditingOriginalText = ""
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        guard let shape = objects[key] as? TextShape else { return }

        if commit, !newText.isEmpty {
            shape.text = newText
            if newText != originalText {
                undoStack.append(.editText(colorKey: key, previous: originalText))
                redoStack.removeAll()
            }
        } else if originalText.isEmpty {
            // 新建后什么都没输入 → 把这条空文字整个撤掉，不留一个看不见的空对象
            // （它在 Layer B 上仍会占一块命中区，点上去会选中一片"什么都没有"）
            objects.removeValue(forKey: key)
            zOrder.removeAll { $0 == key }
            if case .add(let added, _, _)? = undoStack.last,
               added.contains(where: { $0.0 == key }) {
                undoStack.removeLast()
            }
            selectedKey = nil
        } else {
            shape.text = originalText
        }

        hitTestBuffer.redrawAll(objects: objects, zOrder: zOrder)
        refreshDebugView()
        needsDisplay = true
    }

    /// 是否正在编辑文字
    var isEditingText: Bool { textEditingField != nil }
}

// MARK: - NSTextFieldDelegate

extension AnnotationView: NSTextFieldDelegate {

    /// 失焦（点到别处）也会走到这里 —— 那时按"提交"处理，避免输入白费
    func controlTextDidEndEditing(_ obj: Notification) {
        endTextEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        // Esc → 取消。注意必须在 doCommandBy 里拦截：
        // 直接看 keyDown 拿不到，NSTextField 会把按键先消化掉
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing(commit: false)
            return true
        }
        // 回车 → 提交。文字标注是单行的，所以不让回车插换行
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endTextEditing(commit: true)
            return true
        }
        return false
    }
}
