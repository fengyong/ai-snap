import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var regionSelectionWindow: RegionSelectionWindow?
    private var annotationWindow: AnnotationWindow?
    private var settingsWindowController: SettingsWindowController?
    private var historyWindow: HistoryWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()
        setupHotkeys()
        // 首次启动时请求屏幕录制权限
        requestScreenCapturePermission()
        // 自动检查更新默认关闭；开着但没配地址时也直接跳过（不打扰）
        if Preferences.shared.automaticallyChecksForUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.runUpdateCheck(triggeredByUser: false)
            }
        }
    }

    // MARK: - Hotkeys

    /// 注册全局快捷键。改动后（设置窗口）也走这里。
    private func setupHotkeys() {
        let problems = HotkeyRegistration.applyAll(
            regionHandler: { [weak self] in self?.startRegionCapture() },
            windowHandler: { [weak self] in self?.startWindowCapture() }
        )

        guard !problems.isEmpty else { return }

        // 注册失败要主动说 —— 否则用户按快捷键没反应，会以为是应用坏了。
        // 快捷键被占用通常会持续存在，所以每次启动都提醒，直到改掉。
        DispatchQueue.main.async { [weak self] in
            self?.presentHotkeyProblemAlert(problems)
        }
    }

    private func presentHotkeyProblemAlert(_ problems: [String]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "全局快捷键未能全部生效"
        alert.informativeText = problems.joined(separator: "\n") + "\n\n可在「偏好设置」里改键。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开偏好设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            showPreferences()
        }
    }

    /// 截图历史窗口。没有记录时也照常打开 —— 窗口里会说明"还没有记录"，
    /// 比点了菜单什么都不发生要好。
    @objc private func showHistory() {
        if historyWindow == nil {
            let window = HistoryWindow()
            window.onOpen = { [weak self] capture in
                self?.openAnnotationWindow(with: capture)
            }
            historyWindow = window
        }
        historyWindow?.reload()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showPreferences() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController()
            // 改键后重新注册，并把问题回传给设置窗口显示
            controller.onHotkeysChanged = { [weak self] in
                HotkeyRegistration.applyAll(
                    regionHandler: { [weak self] in self?.startRegionCapture() },
                    windowHandler: { [weak self] in self?.startWindowCapture() }
                )
            }
            controller.onCheckForUpdates = { [weak self] in
                self?.runUpdateCheck(triggeredByUser: true)
            }
            settingsWindowController = controller
        }
        settingsWindowController?.present()
    }

    // MARK: - 更新

    @objc private func checkForUpdatesManually() {
        runUpdateCheck(triggeredByUser: true)
    }

    /// 检查更新。
    ///
    /// `triggeredByUser` 决定"没配置 / 失败"要不要出声：手动点的时候必须说明原因，
    /// 而启动时自动检查失败应该**完全静默** —— 一个截图工具因为后台联网失败弹窗，
    /// 是纯粹的打扰。
    private func runUpdateCheck(triggeredByUser: Bool) {
        guard let feedURL = UpdateChecker.configuredFeedURL else {
            guard triggeredByUser else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "还没有配置更新地址"
            alert.informativeText = "在「偏好设置 → 更新」里填入更新清单（appcast）的地址后即可检查。\n\n"
                + "清单是一个 JSON 文件，例如：\n"
                + "{\"version\": \"1.2.0\", \"downloadURL\": \"https://…\", \"notes\": \"修复了…\"}"
            alert.addButton(withTitle: "打开偏好设置")
            alert.addButton(withTitle: "好")
            if alert.runModal() == .alertFirstButtonReturn { showPreferences() }
            return
        }

        UpdateChecker.check(currentVersion: AppInfo.currentVersion,
                            feedURL: feedURL) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .upToDate(let current):
                guard triggeredByUser else { return }
                self.presentUpdateAlert(
                    title: "已是最新版本",
                    text: "当前版本 \(current)。",
                    downloadURL: nil)

            case .updateAvailable(let current, let version, let downloadURL, let notes):
                self.presentUpdateAlert(
                    title: "有新版本 \(version)",
                    text: "当前版本 \(current)。" + (notes.map { "\n\n\($0)" } ?? ""),
                    downloadURL: URL(string: downloadURL))

            case .failed(let reason):
                guard triggeredByUser else { return }
                self.presentUpdateAlert(title: "检查更新失败", text: reason,
                                        downloadURL: nil)
            }
        }
    }

    private func presentUpdateAlert(title: String, text: String, downloadURL: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        if let downloadURL = downloadURL {
            alert.addButton(withTitle: "前往下载")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(downloadURL)
            }
        } else {
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: - Screen Recording Permission

    private func requestScreenCapturePermission() {
        if #available(macOS 10.15, *) {
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
        }
    }

    private func checkScreenCapturePermission() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// 展示屏幕录制权限引导。
    ///
    /// 文案以 `ScreenCaptureError.userMessage` 为单一来源 —— 错误类型本身就携带了
    /// 「该怎么解决」的说明，避免这里再抄一份、日后两处漂移。
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = ScreenCaptureError.permissionDenied.userMessage ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "AISnap")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "区域截图", action: #selector(startRegionCapture), keyEquivalent: "1"))
        menu.addItem(NSMenuItem(title: "窗口截图", action: #selector(startWindowCapture), keyEquivalent: "2"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "截图历史…", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "检查更新…", action: #selector(checkForUpdatesManually), keyEquivalent: ""))
        // 不给 keyEquivalent：状态栏菜单只在菜单展开时响应按键，
        // 标上 ⌘, 会让人以为随时可用，不如不标。
        menu.addItem(NSMenuItem(title: "偏好设置…", action: #selector(showPreferences), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        // 没有贴图时置灰（见 validateMenuItem）
        menu.addItem(NSMenuItem(title: "关闭全部贴图", action: #selector(closeAllPins), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func startRegionCapture() {
        guard checkScreenCapturePermission() else {
            showPermissionAlert()
            return
        }

        // 让本应用已有的窗口先离开屏幕 —— 否则会被冻结进底图
        annotationWindow?.orderOut(nil)
        // 上一次截图若还留着冻结覆盖层（标注窗口被 orderOut 而非 close，
        // onClose 没触发），这里补收一次
        regionSelectionWindow?.hideOverlays()
        regionSelectionWindow = nil

        // 等窗口服务器完成合成，再去冻结屏幕。
        // 这是**一次性**等待，不是每次截图都要付：冻结之后覆盖层显示的是静止画面，
        // 选区确定后只需裁剪冻结图，不再需要「关掉覆盖层 → 等它消失 → 再截图」那一套。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.presentRegionSelection()
        }
    }

    private func presentRegionSelection() {
        let window = RegionSelectionWindow { [weak self] capture in
            guard let self = self else { return }

            guard let capture = capture, capture.anchorRect != nil else {
                // 取消或失败：收掉覆盖层
                self.regionSelectionWindow?.hideOverlays()
                self.regionSelectionWindow = nil
                return
            }
            // 就地编辑：覆盖层先留着当背景（选区四周维持变暗），
            // 等标注窗口关闭时再由 onClose 收掉
            // 记一笔历史。存的是**刚截下来的原图**，不含此后画上去的标注 ——
            // 这样"重新编辑"能从干净的一张图开始（在后台写盘，不挡开窗）
            self.recordHistory(capture)
            self.openAnnotationWindow(with: capture)
        }
        regionSelectionWindow = window

        Task { @MainActor in
            // 先冻结、再显示：覆盖层画的是冻结帧，所以它自己不会被拍进去
            guard await window.freezeScreens() else {
                self.regionSelectionWindow = nil
                self.showCaptureFailureAlert()
                return
            }
            window.beginSelection()
        }
    }

    private func showCaptureFailureAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "屏幕捕获失败"
        alert.informativeText = """
            没能读取屏幕内容，本次截图中止。

            若反复出现，请到 系统设置 → 隐私与安全性 → 屏幕录制 里确认 AISnap 已启用。
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func startWindowCapture() {
        guard checkScreenCapturePermission() else {
            showPermissionAlert()
            return
        }

        // 开新截图会把当前标注窗关掉 —— 有未保存的标注时先问一句，
        // 用户取消就整件事都不做（否则等于用一次菜单点击静默丢掉上一张的成果）
        if let window = annotationWindow {
            guard window.confirmDiscardIfNeeded() else { return }
            window.close()
            annotationWindow = nil
        }

        // 给用户一点时间切换到目标窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let capture = try await ScreenCapture.captureWindowUnderMouse()
                    self.recordHistory(capture)
                    self.openAnnotationWindow(with: capture)
                } catch ScreenCaptureError.permissionDenied {
                    // 旧实现此处只会静默返回 nil，用户点了没反应；现在给出正确引导
                    self.showPermissionAlert()
                } catch {
                    // 鼠标下方没有可捕获的窗口（例如点到了桌面）。
                    // 旧实现在这里是彻底静默（返回 nil，用户点了没任何反馈）；
                    // 现在至少给一声提示音，让用户知道操作被响应了。
                    NSSound.beep()
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 贴图

    @objc private func closeAllPins() {
        PinManager.shared.closeAll()
    }

    /// 「关闭全部贴图」在没有贴图时置灰 —— 否则点了没反应，像是坏了。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeAllPins) {
            return PinManager.shared.hasPins
        }
        return true
    }

    // MARK: - Annotation

    /// 记一笔截图历史。受偏好开关控制（默认开）。
    ///
    /// 开关关掉时**连写盘都不发生** —— 截图常含敏感内容，用户对"我没保存的东西
    /// 却躺在磁盘上"的接受度因人而异，所以开关必须是真的开关，而不是"少显示几条"。
    private func recordHistory(_ capture: CapturedImage) {
        guard Preferences.shared.recordHistory else { return }
        CaptureHistory.shared.record(capture.image, pixelScale: capture.pixelScale)
    }

    /// 打开标注窗口。
    ///
    /// 逻辑尺寸取捕获方**实测反推**的倍率（`CapturedImage.logicalSize`），
    /// 不再自己读 `backingScaleFactor`：那是"显示侧用屏幕倍率、裁剪侧用反推"的双轨制，
    /// 两者一旦不符（跨屏 / 降级 1x），画布会与选区错位，而这个错位只在真机上才看得见。
    private func openAnnotationWindow(with capture: CapturedImage) {
        let nsImage = NSImage(cgImage: capture.image, size: capture.logicalSize)

        let window = AnnotationWindow(image: nsImage, anchor: capture.anchorRect)
        if capture.anchorRect != nil {
            // 标注窗口关闭时收掉冻结覆盖层 —— 覆盖层的所有权在 regionSelectionWindow 手上，
            // 标注窗口只负责通知
            window.onClose = { [weak self] in
                self?.regionSelectionWindow?.hideOverlays()
                self?.regionSelectionWindow = nil
            }
        }

        annotationWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
