import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var regionSelectionWindow: RegionSelectionWindow?
    private var annotationWindow: AnnotationWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()
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
