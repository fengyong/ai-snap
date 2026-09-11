import Cocoa
import Carbon.HIToolbox

/// 偏好设置窗口。
///
/// 只有「全局快捷键」与「更新」两组设置 —— 线宽、颜色、线型、箭头样式、水印都已经在
/// 标注窗口的工具栏里，**再放一份到这里只会造出两个能改同一份数据的地方**
/// （改了一处另一处不刷新，用户看到的状态就自相矛盾）。
/// 这两组都没有别的入口，所以只有它们需要这个窗口。
final class SettingsWindowController: NSWindowController {

    /// 快捷键改动后由外部（AppDelegate）重新注册，并把问题反馈回来。
    /// 用闭包而不是让设置窗口去调 AppDelegate，避免两边互相持有。
    var onHotkeysChanged: (() -> [String])?

    /// 「立即检查更新」交给 AppDelegate 去执行 —— 检查完要弹窗、还要打开浏览器，
    /// 那是应用级的事情，不是设置窗口的职责。
    var onCheckForUpdates: (() -> Void)?

    private var regionButton: NSButton!
    private var windowButton: NSButton!
    private var statusLabel: NSTextField!
    private var feedURLField: NSTextField!
    private var autoCheckBox: NSButton!
    private var keyMonitor: Any?
    /// 正在录制的目标：nil 表示没有在录制
    private var recordingTarget: RecordingTarget?

    private enum RecordingTarget {
        case region
        case window
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AISnap 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
        refreshFromPreferences()
    }

    deinit {
        stopRecording()
    }

    // MARK: - UI

    private func buildUI() {
        guard let window = window else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "全局快捷键")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(title)

        regionButton = makeRecorderButton(action: #selector(recordRegion))
        windowButton = makeRecorderButton(action: #selector(recordWindow))
        root.addArrangedSubview(makeRow(label: "区域截图", button: regionButton))
        root.addArrangedSubview(makeRow(label: "窗口截图", button: windowButton))

        let hint = NSTextField(wrappingLabelWithString:
            "点击按钮后按下新的组合键，按 Esc 取消。组合键需包含 ⌘ 或 ⌃ —— 只用 ⇧ / ⌥ 会抢掉系统范围内的正常打字。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(hint)

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .systemOrange
        statusLabel.preferredMaxLayoutWidth = 420
        statusLabel.isHidden = true
        root.addArrangedSubview(statusLabel)

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)

        // ── 更新 ──
        let updateTitle = NSTextField(labelWithString: "更新")
        updateTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(updateTitle)

        let urlRow = NSStackView()
        urlRow.orientation = .horizontal
        urlRow.spacing = 12
        let urlLabel = NSTextField(labelWithString: "清单地址")
        urlLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        urlRow.addArrangedSubview(urlLabel)

        feedURLField = NSTextField(string: "")
        feedURLField.placeholderString = "https://…/latest.json（留空则不检查）"
        feedURLField.font = NSFont.systemFont(ofSize: 12)
        feedURLField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        feedURLField.target = self
        feedURLField.action = #selector(feedURLChanged(_:))
        urlRow.addArrangedSubview(feedURLField)
        root.addArrangedSubview(urlRow)

        autoCheckBox = NSButton(checkboxWithTitle: "启动时自动检查更新",
                                target: self, action: #selector(autoCheckToggled(_:)))
        root.addArrangedSubview(autoCheckBox)

        let updateHint = NSTextField(wrappingLabelWithString:
            "清单是一个 JSON 文件：{\"version\":\"1.2.0\", \"downloadURL\":\"https://…\", \"notes\":\"…\"}。\n"
            + "目前只会提示并跳到下载页，不会自动替换应用本身 —— 那需要先做代码签名与公证。")
        updateHint.font = NSFont.systemFont(ofSize: 11)
        updateHint.textColor = .secondaryLabelColor
        updateHint.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(updateHint)

        let checkRow = NSStackView()
        checkRow.orientation = .horizontal
        checkRow.spacing = 8
        checkRow.addArrangedSubview(NSButton(title: "立即检查更新",
                                             target: self, action: #selector(checkNow)))
        root.addArrangedSubview(checkRow)

        let separator2 = NSBox()
        separator2.boxType = .separator
        root.addArrangedSubview(separator2)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let resetHotkeys = NSButton(title: "恢复默认快捷键",
                                    target: self, action: #selector(resetHotkeys))
        buttonRow.addArrangedSubview(resetHotkeys)

        let resetAll = NSButton(title: "恢复全部默认设置",
                                target: self, action: #selector(resetAll))
        buttonRow.addArrangedSubview(resetAll)

        root.addArrangedSubview(buttonRow)

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        window.contentView = container
        window.setContentSize(container.fittingSize)
    }

    private func makeRecorderButton(action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .rounded
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        return button
    }

    private func makeRow(label: String, button: NSButton) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12

        let text = NSTextField(labelWithString: label)
        text.widthAnchor.constraint(equalToConstant: 80).isActive = true
        row.addArrangedSubview(text)
        row.addArrangedSubview(button)
        return row
    }

    /// 让窗口显示在已存偏好上。
    private func refreshFromPreferences() {
        regionButton.title = Preferences.shared.regionCaptureHotkey.displayString
        windowButton.title = Preferences.shared.windowCaptureHotkey.displayString
        feedURLField.stringValue = Preferences.shared.updateFeedURL
        autoCheckBox.state = Preferences.shared.automaticallyChecksForUpdates ? .on : .off
    }

    // MARK: - 更新设置

    @objc private func feedURLChanged(_ sender: NSTextField) {
        Preferences.shared.updateFeedURL =
            sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func autoCheckToggled(_ sender: NSButton) {
        Preferences.shared.automaticallyChecksForUpdates = (sender.state == .on)
    }

    @objc private func checkNow() {
        // 先落盘再检查：用户可能刚改完地址就直接点检查，不等焦点离开输入框
        Preferences.shared.updateFeedURL =
            feedURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onCheckForUpdates?()
    }

    private func showProblems(_ problems: [String]) {
        statusLabel.stringValue = problems.joined(separator: "\n")
        statusLabel.isHidden = problems.isEmpty
        statusLabel.textColor = problems.isEmpty ? .secondaryLabelColor : .systemOrange
        if let window = window, !problems.isEmpty {
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        }
    }

    // MARK: - 录键

    @objc private func recordRegion() { startRecording(.region) }
    @objc private func recordWindow() { startRecording(.window) }

    private func startRecording(_ target: RecordingTarget) {
        stopRecording()                     // 防止重复点击装出多个键盘监视器
        recordingTarget = target
        statusLabel.isHidden = true

        let active = (target == .region) ? regionButton : windowButton
        active?.title = "按下新的组合键…"

        // 本地监视器而不是全局：录制期间本应用是前台，本地监视器足够，
        // 而且它**能拦截**事件（全局监视器只能旁观，退格键之类会漏给下层控件）。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleRecordedKey(event)
            return nil                      // 吞掉这次按键，不让它传给窗口
        }
    }

    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        recordingTarget = nil
        refreshFromPreferences()            // 取消时把按钮标题还原成实际生效的值
    }

    private func handleRecordedKey(_ event: NSEvent) {
        guard let target = recordingTarget else { return }

        // Esc 取消
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return
        }

        let modifiers = HotkeyConfig.carbonModifiers(from: event.modifierFlags)
        let config = HotkeyConfig(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)

        // 只按修饰键（⌘、⇧ 本身）时 keyCode 是修饰键、组合不完整 → 继续等
        guard config.isUsable else {
            statusLabel.stringValue = "组合键需包含 ⌘ 或 ⌃（只用 ⇧ / ⌥ 会抢掉正常打字），且需为字母、数字或常用符号。"
            statusLabel.isHidden = false
            return
        }

        if HotkeyConfig.systemScreenshotCombos.contains(config) {
            statusLabel.stringValue = "\(config.displayString) 是系统截图的快捷键，请换一个组合。"
            statusLabel.isHidden = false
            return
        }

        switch target {
        case .region: Preferences.shared.regionCaptureHotkey = config
        case .window: Preferences.shared.windowCaptureHotkey = config
        }

        stopRecording()
        showProblems(onHotkeysChanged?() ?? [])
    }

    // MARK: - 恢复默认

    @objc private func resetHotkeys() {
        Preferences.shared.regionCaptureHotkey = Preferences.Defaults.regionCaptureHotkey
        Preferences.shared.windowCaptureHotkey = Preferences.Defaults.windowCaptureHotkey
        refreshFromPreferences()
        showProblems(onHotkeysChanged?() ?? [])
    }

    @objc private func resetAll() {
        Preferences.shared.resetToDefaults()
        refreshFromPreferences()
        showProblems(onHotkeysChanged?() ?? [])
        // 说明影响范围：已打开的标注窗口里控件仍持有旧值，一动就会写回偏好，
        // 所以不做「立即全部生效」的假象。
        statusLabel.stringValue = "已恢复默认设置。线宽、颜色、线型、箭头样式、调色板、水印与默认工具均已回出厂值；\n已打开的标注窗口不受影响，下次截图时生效。"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
    }

    /// 供 AppDelegate 调用：窗口显示前先同步一次已存值。
    func present() {
        stopRecording()
        showProblems([])
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
