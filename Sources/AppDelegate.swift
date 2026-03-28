import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var regionSelectionWindow: RegionSelectionWindow?
    private var annotationWindow: AnnotationWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()
        // 首次启动时请求屏幕录制权限
        requestScreenCapturePermission()
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

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "AISnap 需要屏幕录制权限才能截图。\n\n请前往 系统设置 → 隐私与安全性 → 屏幕录制，启用 AISnap 后重试。"
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
        guard checkScreenCapturePermission() else {
            showPermissionAlert()
            return
        }

        annotationWindow?.close()
        annotationWindow = nil

        regionSelectionWindow = RegionSelectionWindow { [weak self] image in
            self?.regionSelectionWindow = nil
            if let image = image {
                self?.openAnnotationWindow(with: image)
            }
        }
        regionSelectionWindow?.beginSelection()
    }

    @objc private func startWindowCapture() {
        guard checkScreenCapturePermission() else {
            showPermissionAlert()
            return
        }

        annotationWindow?.close()
        annotationWindow = nil

        // 给用户一点时间切换到目标窗口
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let image = ScreenCapture.captureWindowUnderMouse() {
                self.openAnnotationWindow(with: image)
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
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
