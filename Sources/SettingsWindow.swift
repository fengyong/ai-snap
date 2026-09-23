import Cocoa
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// 偏好设置窗口。
///
/// 这里只放**没有别的入口**的设置：全局快捷键（含忽略应用列表）、状态栏按键动作、
/// 开机启动、截图历史、更新。线宽、颜色、线型、箭头样式、水印已经在标注窗口的工具栏里，
/// **再放一份到这里只会造出两个能改同一份数据的地方**
/// （改了一处另一处不刷新，用户看到的状态就自相矛盾）。
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
    private var launchAtLoginBox: NSButton!
    private var recordHistoryBox: NSButton!
    /// 忽略应用列表的行容器（列表变化时整体重建）
    private var ignoredAppsBox: NSStackView!
    /// 状态栏左/右/中键动作下拉框
    private var trayLeftPopup: NSPopUpButton!
    private var trayRightPopup: NSPopUpButton!
    private var trayMiddlePopup: NSPopUpButton!
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

        // ── 忽略的应用程序 ──
        let ignoreTitle = NSTextField(labelWithString: "在这些应用中忽略快捷键")
        ignoreTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        root.addArrangedSubview(ignoreTitle)

        ignoredAppsBox = NSStackView()
        ignoredAppsBox.orientation = .vertical
        ignoredAppsBox.alignment = .leading
        ignoredAppsBox.spacing = 6
        ignoredAppsBox.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        root.addArrangedSubview(ignoredAppsBox)

        let addAppButton = NSButton(title: "＋ 添加应用程序…",
                                    target: self, action: #selector(addIgnoredApp))
        addAppButton.bezelStyle = .rounded
        root.addArrangedSubview(addAppButton)

        let ignoreHint = NSTextField(wrappingLabelWithString:
            "列表中的应用处于前台时，截图快捷键不会触发。受 macOS 限制，被拦截的按键不会转发给该应用"
            + "（默认组合 ⌃⌘A / ⌃⌘W 很冷门，一般无影响）。支持 bundle id 前缀规则，以 * 结尾。")
        ignoreHint.font = NSFont.systemFont(ofSize: 11)
        ignoreHint.textColor = .secondaryLabelColor
        ignoreHint.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(ignoreHint)

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)

        // ── 启动 ──
        let launchTitle = NSTextField(labelWithString: "启动")
        launchTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(launchTitle)

        launchAtLoginBox = NSButton(checkboxWithTitle: "开机自动启动（登录后在后台待命）",
                                    target: self, action: #selector(launchAtLoginToggled(_:)))
        root.addArrangedSubview(launchAtLoginBox)

        let launchHint = NSTextField(wrappingLabelWithString:
            "AISnap 常驻状态栏、不占 Dock，截图靠全局快捷键 —— 所以它需要一直在后台待命。"
            + "打开这个开关就不用每次重启后手动启动。")
        launchHint.font = NSFont.systemFont(ofSize: 11)
        launchHint.textColor = .secondaryLabelColor
        launchHint.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(launchHint)

        let separator1 = NSBox()
        separator1.boxType = .separator
        root.addArrangedSubview(separator1)

        // ── 截图历史 ──
        let historyTitle = NSTextField(labelWithString: "截图历史")
        historyTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(historyTitle)

        recordHistoryBox = NSButton(checkboxWithTitle: "保留截图历史（含没有保存的）",
                                    target: self, action: #selector(recordHistoryToggled(_:)))
        root.addArrangedSubview(recordHistoryBox)

        let historyHint = NSTextField(wrappingLabelWithString:
            "开启后每次截图都会在原图存一份，最多保留最近 \(CaptureHistory.maximumEntries) 张，"
            + "可以在「截图历史」窗口里重新编辑或清理。"
            + "截图常含敏感内容，不需要就到状态栏菜单 →「截图历史…」里删掉，或在这里关掉。")
        historyHint.font = NSFont.systemFont(ofSize: 11)
        historyHint.textColor = .secondaryLabelColor
        historyHint.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(historyHint)

        let separatorHistory = NSBox()
        separatorHistory.boxType = .separator
        root.addArrangedSubview(separatorHistory)

        // ── 状态栏图标 ──
        let trayTitle = NSTextField(labelWithString: "状态栏图标")
        trayTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(trayTitle)

        trayLeftPopup = makeTrayPopup()
        trayRightPopup = makeTrayPopup()
        trayMiddlePopup = makeTrayPopup()
        root.addArrangedSubview(makeTrayRow(label: "左键", popup: trayLeftPopup))
        root.addArrangedSubview(makeTrayRow(label: "右键", popup: trayRightPopup))
        root.addArrangedSubview(makeTrayRow(label: "中键", popup: trayMiddlePopup))

        let trayHint = NSTextField(wrappingLabelWithString:
            "分别绑定单击状态栏图标的动作，修改即时生效。至少保留一个按键为「弹出菜单」，"
            + "否则将无法从状态栏打开偏好设置、截图历史或退出。")
        trayHint.font = NSFont.systemFont(ofSize: 11)
        trayHint.textColor = .secondaryLabelColor
        trayHint.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(trayHint)

        let separatorTray = NSBox()
        separatorTray.boxType = .separator
        root.addArrangedSubview(separatorTray)

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
            // 【必须有 bottom】否则 container 在竖直方向是无约束的，
            // fittingSize.height 会退化成 0 —— 紧接着的 setContentSize 就把窗口
            // 压成一条只剩标题栏的细缝（实测 440×28），表现为"点了偏好设置没反应"。
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.setContentSize(container.fittingSize)
        // 尺寸定下来之后再居中：构造时的 center() 用的是临时尺寸，
        // setContentSize 之后窗口会偏。
        window.center()
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
        recordHistoryBox.state = Preferences.shared.recordHistory ? .on : .off
        rebuildIgnoredAppsList()
        syncTrayPopupsToPreferences()
        refreshLaunchAtLogin()
    }

    /// 内容行数变化后重算窗口高度（与 launchAtLoginToggled 里同一手法）。
    private func fitWindow() {
        guard let window = window else { return }
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
    }

    @objc private func recordHistoryToggled(_ sender: NSButton) {
        Preferences.shared.recordHistory = (sender.state == .on)
    }

    // MARK: - 忽略的应用程序

    /// 按偏好重建忽略列表的行。整体重建最省心：增删之后不必手工对齐行与数据。
    private func rebuildIgnoredAppsList() {
        ignoredAppsBox.subviews.forEach { $0.removeFromSuperview() }

        let ids = Preferences.shared.ignoredBundleIdentifiers
        if ids.isEmpty {
            let empty = NSTextField(labelWithString: "（无）所有应用中快捷键都正常生效")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            ignoredAppsBox.addArrangedSubview(empty)
            return
        }

        for id in ids {
            ignoredAppsBox.addArrangedSubview(makeIgnoredAppRow(bundleID: id))
        }
    }

    private func makeIgnoredAppRow(bundleID: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let name = displayName(forBundleID: bundleID)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = NSFont.systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(nameLabel)

        // 显示名与 bundle id 不同时，把灰色 id 附在后面，方便确认选对了应用
        if name != bundleID {
            let idLabel = NSTextField(labelWithString: bundleID)
            idLabel.font = NSFont.systemFont(ofSize: 10)
            idLabel.textColor = .secondaryLabelColor
            idLabel.lineBreakMode = .byTruncatingTail
            idLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(idLabel)
        }

        let remove = NSButton(title: "－", target: self, action: #selector(removeIgnoredApp(_:)))
        remove.bezelStyle = .rounded
        remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
        remove.toolTip = "移除"
        row.addArrangedSubview(remove)

        row.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        return row
    }

    /// 用 bundle id 反查应用显示名；查不到（应用已卸载/是前缀规则）就直接显示 id。
    private func displayName(forBundleID id: String) -> String {
        if id.hasSuffix("*") { return id }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
              let bundle = Bundle(url: url) else { return id }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty { return display }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return id
    }

    @objc private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.title = "选择要忽略快捷键的应用"
        panel.message = "可多选。选中的应用处于前台时，截图全局快捷键不会触发。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.application]
        guard let window = window else { return }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self else { return }

            var ids = Preferences.shared.ignoredBundleIdentifiers
            var unreadable: [String] = []
            for appURL in panel.urls {
                guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
                    unreadable.append(appURL.deletingPathExtension().lastPathComponent)
                    continue
                }
                if !ids.contains(bundleID) { ids.append(bundleID) }
            }
            Preferences.shared.ignoredBundleIdentifiers = ids
            self.rebuildIgnoredAppsList()
            self.fitWindow()

            if !unreadable.isEmpty {
                let alert = NSAlert()
                alert.messageText = "部分应用无法识别"
                alert.informativeText = "以下应用读不到 bundle identifier，未加入列表：\n"
                    + unreadable.joined(separator: "、")
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func removeIgnoredApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var ids = Preferences.shared.ignoredBundleIdentifiers
        ids.removeAll { $0 == id }
        Preferences.shared.ignoredBundleIdentifiers = ids
        rebuildIgnoredAppsList()
        fitWindow()
    }

    // MARK: - 状态栏按键动作

    private func makeTrayPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for action in TrayClickAction.allCases {
            let item = NSMenuItem(title: action.displayName, action: nil, keyEquivalent: "")
            item.representedObject = action.rawValue
            popup.menu?.addItem(item)
        }
        popup.target = self
        popup.action = #selector(trayActionChanged(_:))
        return popup
    }

    private func makeTrayRow(label: String, popup: NSPopUpButton) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        let text = NSTextField(labelWithString: label)
        text.widthAnchor.constraint(equalToConstant: 80).isActive = true
        row.addArrangedSubview(text)
        row.addArrangedSubview(popup)
        return row
    }

    private func syncTrayPopupsToPreferences() {
        select(trayLeftPopup, action: Preferences.shared.trayLeftAction)
        select(trayRightPopup, action: Preferences.shared.trayRightAction)
        select(trayMiddlePopup, action: Preferences.shared.trayMiddleAction)
    }

    private func select(_ popup: NSPopUpButton, action: TrayClickAction) {
        guard let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == action.rawValue
        }) else { return }
        popup.select(item)
    }

    private func selectedAction(_ popup: NSPopUpButton) -> TrayClickAction {
        guard let raw = popup.selectedItem?.representedObject as? String,
              let action = TrayClickAction(rawValue: raw) else { return .menu }
        return action
    }

    @objc private func trayActionChanged(_ sender: NSPopUpButton) {
        let left = selectedAction(trayLeftPopup)
        let right = selectedAction(trayRightPopup)
        let middle = selectedAction(trayMiddlePopup)

        // 兜底守卫：三个键必须留一个「弹出菜单」，否则状态栏里再也到不了偏好/历史/退出。
        // 拒绝本次修改：不落盘，并把控件回滚为已存值。
        guard [left, right, middle].contains(.menu) else {
            syncTrayPopupsToPreferences()
            statusLabel.stringValue = Self.menuGuardMessage
            statusLabel.textColor = .systemOrange
            statusLabel.isHidden = false
            fitWindow()
            return
        }

        Preferences.shared.trayLeftAction = left
        Preferences.shared.trayRightAction = right
        Preferences.shared.trayMiddleAction = middle
        // 若此前显示的是本功能的守卫告警，现在状态合法了，收掉它；
        // 热键注册等其它告警按文案区分，不误清。
        if statusLabel.stringValue == Self.menuGuardMessage {
            statusLabel.isHidden = true
        }
    }

    private static let menuGuardMessage =
        "至少保留一个按键为「弹出菜单」，否则将无法打开偏好设置与退出。"

    // MARK: - 开机启动

    /// 以**系统状态**回写控件。不能用「用户点了什么」当作显示状态：
    /// 注册可能失败、也可能需要用户去系统设置里批准，那时勾选框不能显示成已设置 ——
    /// 否则关掉窗口再打开会看到它自己变回去了，用户只会觉得这个开关坏了。
    private func refreshLaunchAtLogin() {
        launchAtLoginBox.state = (LaunchAtLogin.status == .enabled) ? .on : .off
        launchAtLoginBox.isEnabled = (LaunchAtLogin.status != .unavailable)
        if LaunchAtLogin.status == .unavailable {
            launchAtLoginBox.toolTip = "需要从「应用程序」里的 AISnap 使用"
        }
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        if let problem = LaunchAtLogin.setEnabled(sender.state == .on) {
            statusLabel.stringValue = problem
            statusLabel.textColor = .systemOrange
            statusLabel.isHidden = false
        }
        refreshLaunchAtLogin()
        if let window = window {
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        }
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

        // 走到这里的只可能是"完整但不可用的组合"（如 ⇧A、⌥A）——
        // 纯修饰键根本不会产生 keyDown（那是 flagsChanged），所以不存在
        // "用户正在按修饰键、我们继续等"的情形。原先的注释写成那样是错的。
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
        // 每次都重新读：开机启动的真实状态在系统手里，用户可能在
        // 「系统设置 → 通用 → 登录项与扩展」里改过，窗口不能显示上次的旧值
        refreshFromPreferences()
        showProblems([])
        // 忽略列表可能在窗口关闭期间被（未来的）其他入口改动，重新按内容量高度
        fitWindow()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
