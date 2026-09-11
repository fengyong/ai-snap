import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var regionSelectionWindow: RegionSelectionWindow?
    private var annotationWindow: AnnotationWindow?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()
        setupHotkeys()
        // 首次启动时请求屏幕录制权限
        requestScreenCapturePermission()
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
            settingsWindowController = controller
        }
        settingsWindowController?.present()
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

        // 等窗口服务器完成合成，再去冻结屏幕。
        // 这是**一次性**等待，不是每次截图都要付：冻结之后覆盖层显示的是静止画面，
        // 选区确定后只需裁剪冻结图，不再需要「关掉覆盖层 → 等它消失 → 再截图」那一套。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.presentRegionSelection()
        }
    }

    private func presentRegionSelection() {
        let window = RegionSelectionWindow { [weak self] image in
            self?.regionSelectionWindow = nil
            if let image = image {
                self?.openAnnotationWindow(with: image)
            }
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

        annotationWindow?.close()
        annotationWindow = nil

        // 给用户一点时间切换到目标窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let image = try await ScreenCapture.captureWindowUnderMouse()
                    self.openAnnotationWindow(with: image)
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

    private func openAnnotationWindow(with image: CGImage) {
        // 用屏幕 backingScaleFactor 将像素尺寸换算为逻辑点尺寸
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        let logicalSize = NSSize(width: CGFloat(image.width) / scaleFactor,
                                 height: CGFloat(image.height) / scaleFactor)
        let nsImage = NSImage(cgImage: image, size: logicalSize)
        annotationWindow = AnnotationWindow(image: nsImage)
        annotationWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
