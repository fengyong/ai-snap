import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var regionSelectionWindow: RegionSelectionWindow?
    private var annotationWindow: AnnotationWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()
        requestScreenCapturePermission()
        // 用户可能是在"运行中"去系统设置里授权的：回到前台时重新检测一次
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidBecomeActive),
                                               name: NSApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    @objc private func applicationDidBecomeActive() {
        if !hasScreenCapturePermission && pendingCaptureIntent != nil {
            // 用户刚去授权，回来就继续原来的意图
            let intent = pendingCaptureIntent
            pendingCaptureIntent = nil
            if hasScreenCapturePermission {
                switch intent {
                case .region: startRegionCapture()
                case .window: startWindowCapture()
                case .none: break
                }
            }
        }
    }

    private enum CaptureIntent { case region, window }
    private var pendingCaptureIntent: CaptureIntent?
    /// 等待 0.5s 后执行的那次窗口截图（用于防重入）
    private var pendingWindowCapture: DispatchWorkItem?

    // MARK: - Screen Recording Permission

    private func requestScreenCapturePermission() {
        if !hasScreenCapturePermission {
            CGRequestScreenCaptureAccess()
        }
    }

    /// 只用 `CGPreflightScreenCaptureAccess()` 会碰到"明明授权了却报 false"的假阴性，
    /// 因此这里再加一次真实的极小截图探测作为兜底。
    private var hasScreenCapturePermission: Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard let probe = CGWindowListCreateImage(CGRect(x: 0, y: 0, width: 1, height: 1),
                                                  .optionOnScreenOnly, kCGNullWindowID,
                                                  [.bestResolution]) else {
            return false
        }
        return !ScreenCapture.isFullyTransparent(probe)
    }

    private func showPermissionAlert(for intent: CaptureIntent) {
        pendingCaptureIntent = intent
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "AISnap 需要屏幕录制权限才能截图。\n\n请前往 系统设置 → 隐私与安全性 → 屏幕录制，启用 AISnap 后回到本应用会自动继续。"
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
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func startRegionCapture() {
        guard hasScreenCapturePermission else {
            showPermissionAlert(for: .region)
            return
        }
        guard closeAnnotationIfNeeded() else { return }

        // 上一次选区若还在（覆盖层挡住了状态栏，正常点不到，但键盘/脚本可能触发），先收掉，避免窗口残留
        regionSelectionWindow?.cancelSelection()
        regionSelectionWindow = nil

        let selection = RegionSelectionWindow { [weak self] result in
            self?.regionSelectionWindow = nil
            guard let self = self else { return }
            if let result = result {
                self.openAnnotationWindow(with: result)
            }
        }
        regionSelectionWindow = selection
        selection.beginSelection()
    }

    @objc private func startWindowCapture() {
        guard hasScreenCapturePermission else {
            showPermissionAlert(for: .window)
            return
        }
        guard closeAnnotationIfNeeded() else { return }

        // 防重入：0.5s 内被触发两次会产生两个标注窗口，
        // 而 annotationWindow 只记得住最后一个 —— 前一个会变成无人托管、
        // 既不会被关掉也不会被确认丢弃的游离窗口（区域截图那条路径已有等价保护）
        pendingWindowCapture?.cancel()

        // 给用户一点时间把鼠标移到目标窗口（菜单栏菜单还没完全收起）
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingWindowCapture = nil
            if let result = ScreenCapture.captureWindowUnderMouse() {
                self.openAnnotationWindow(with: result)
            } else {
                self.showCaptureFailureAlert()
            }
        }
        pendingWindowCapture = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Annotation

    /// 打开新的标注窗口前，先确认当前标注不会被静默丢弃（P2-3 / P4-20）
    private func closeAnnotationIfNeeded() -> Bool {
        guard let window = annotationWindow else { return true }
        guard window.confirmDiscardIfNeeded() else { return false }
        window.delegate = nil          // 避免 close() 再弹一次确认
        window.close()
        annotationWindow = nil
        // 激活策略由 AnnotationWindow.close() 统一恢复为 .accessory ——
        // 放在那边才能覆盖"delegate 被置空因而收不到 windowWillClose"这条路径。
        return true
    }

    private func openAnnotationWindow(with result: CaptureResult) {
        // 逻辑尺寸取自"捕获屏"的 backingScaleFactor，而不是事后猜 NSScreen.main（P2-6）
        let logicalSize = result.logicalSize
        let nsImage = NSImage(cgImage: result.image, size: logicalSize)
        let pixelSize = CGSize(width: result.image.width, height: result.image.height)
        let window = AnnotationWindow(image: nsImage, screen: result.screen, pixelSize: pixelSize)
        annotationWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showCaptureFailureAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "没有找到可截图的窗口"
        alert.informativeText = "请把鼠标移到目标窗口上再试一次。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}
