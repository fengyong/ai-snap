import Cocoa
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    /// 状态栏菜单。不再直接挂到 `statusItem.menu`（那样左键/右键都只会弹菜单、无法绑动作），
    /// 而是在按键动作解析为 `.menu` 时由我们自己弹出（见 `statusBarClicked(_:)`）。
    private var statusMenu: NSMenu!
    private var regionSelectionWindow: RegionSelectionWindow?

    /// 每次发起截图都 +1 的代号。
    ///
    /// 用来作废"迟到的异步任务"：`presentRegionSelection` 里的 Task 强持有那个 window，
    /// 并在 `await freezeScreens()` 之后**无条件** `beginSelection()`（它会
    /// `makeKeyAndOrderFront` + 把每个覆盖层 `orderFront`）。用户在冻结完成前再按一次
    /// 快捷键时，第一次的 Task 醒来后仍会把一个**已经无主**的覆盖层推上屏 —— 屏幕上
    /// 多出一个没人管的僵尸覆盖层。有代号就能让迟到的那次直接放弃并自己收干净。
    private var captureGeneration = 0

    /// 窗口截图是否正在"0.5 秒等待 + 捕获"当中。防重入用。
    ///
    /// 这条流程里有一段"给用户时间切换到目标窗口"的延迟加一次异步捕获；期间再按一次
    /// 快捷键会调度出第二次，第二次的 `openAnnotationWindow` 会覆盖 `annotationWindow`
    /// 引用 —— 第一张标注图连同它的窗口一起被丢掉。
    private var windowCaptureInFlight = false
    private var annotationWindow: AnnotationWindow?
    private var settingsWindowController: SettingsWindowController?
    private var historyWindow: HistoryWindow?

    /// ⌘Q / 菜单里的「退出 AISnap」也要走一遍"放弃标注"的确认。
    ///
    /// 之前只覆盖了标题栏 X 与工具栏「放弃」按钮 —— 按 ⌘Q 会**直接退出**，
    /// 图上的标注静默丢失，连一句提示都没有。数据丢失的口子留一个就等于没堵。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let window = annotationWindow else { return .terminateNow }
        return window.confirmDiscardIfNeeded() ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()
        setupHotkeys()
        // 首次启动时请求屏幕录制权限
        requestScreenCapturePermission()
        // 清掉历史遗留的临时 PNG（复制图片会写一份，但以前从不清理）
        AnnotationWindow.cleanUpTemporaryPNGs()
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
            regionHandler: { [weak self] in self?.performHotkeyAction { self?.startRegionCapture() } },
            windowHandler: { [weak self] in self?.performHotkeyAction { self?.startWindowCapture() } }
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

    /// 全局热键动作的统一入口：前台应用命中忽略列表时直接跳过。
    ///
    /// **只能包热键回调**，不能加进 `startRegionCapture`/`startWindowCapture` 本身 ——
    /// 那两个方法也被状态栏菜单调用，用户主动点菜单时不应受忽略列表影响。
    /// 判定必须在一切开窗/激活动作之前同步完成：Carbon 热键不会激活本应用，
    /// 此刻 frontmostApplication 仍是用户所在的 app，判定才准确。
    private func performHotkeyAction(_ action: () -> Void) {
        guard !isFrontmostAppIgnored() else { return }
        action()
    }

    private func isFrontmostAppIgnored() -> Bool {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return HotkeyIgnorePolicy.isIgnored(bundleID: bundleID,
                                            rules: Preferences.shared.ignoredBundleIdentifiers)
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
                    regionHandler: { [weak self] in self?.performHotkeyAction { self?.startRegionCapture() } },
                    windowHandler: { [weak self] in self?.performHotkeyAction { self?.startWindowCapture() } }
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

    /// 权限判定。
    ///
    /// `CGPreflightScreenCaptureAccess()` 有一个众所周知的假阴性：用户到系统设置里
    /// 授权之后，**同一个进程生命周期内它仍可能返回 false**（系统要求重启应用才更新
    /// 这个标志）。只信它的话，用户明明已经授权，却被反复引导去授权 —— 怎么点都没用。
    ///
    /// 所以 preflight 返回 false 时再探一次。**但兜底判据不能用像素**：
    /// 没有权限时 `CGWindowListCreateImage` 依然会返回一张**非 nil、完全不透明**的
    /// 桌面图 —— 按"有没有非透明像素"判定会**恒为真**，等于把权限门整个删掉。
    /// 实测对照（同一个二进制，只换运行身份）：
    ///
    /// | 运行方式 | preflight | 像素探测 |
    /// |---|---|---|
    /// | 直接跑（已授权） | `true` | `true` |
    /// | 经 `launchctl` 跑（无授权） | `false` | **`true`** ← 误判 |
    ///
    /// 无权限那次的探测像素是 `(45,45,50,255)`，四个像素一模一样 —— 那是壁纸，不是屏幕内容。
    ///
    /// 改用 ScreenCaptureKit 的**权限专属信号**：没有权限时 `SCShareableContent`
    /// 抛 `SCStreamErrorDomain -3801`（「用户拒绝了…TCC」），有权限时正常返回。
    /// 这也正是抓图本身用的框架，顺带把已经迁走的 deprecated API 从本文件清掉。
    ///
    /// 非 private：探针要直接验证"已授权时不得被判成无权限"。
    func checkScreenCapturePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return await canQueryShareableContent()
    }

    /// 用 `SCShareableContent` 探测权限（权限专属信号，见上）。
    ///
    /// **fail-closed**：任何失败都按无权限处理 —— 报错、拿不到答案一律 false，
    /// 宁可多弹一次授权引导，也不能让用户在没有权限的情况下截出一张黑图还不知道为什么。
    /// 反方向不可能出错：只有 SCK **成功**才判 true，而成功本身就等于实时 TCC 说"允许"。
    ///
    /// 曾经是"信号量 + 1 秒超时"的同步版本，为的是迁就两个同步调用点。代价是
    /// SCK 偶发慢时**主线程整整卡 1 秒**（截图入口，用户直接能感觉到）。
    /// 现在两个调用点都改成 `Task { @MainActor in ... }` + `await`，主线程照常跑 runloop。
    ///
    /// **超时仍然要留**，只是从"阻塞主线程"换成"不阻塞"：SCK 万一不回来，这个 Task 会
    /// 永远挂着，用户按快捷键**什么反应都没有** —— 那比卡 1 秒更难查。用 task group
    /// 让"探测"和"计时"赛跑，谁先回来算谁。
    func canQueryShareableContent(timeout: TimeInterval = 3) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil          // 超时：拿不到答案
            }
            // 第一个完成的说了算；超时那条返回 nil，于是 fail-closed 成 false
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
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
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "camera.viewfinder",
                               accessibilityDescription: "AISnap")

        statusMenu = makeStatusMenu()

        // 关键：**不要**设 `statusItem.menu`。一旦设置，AppKit 会在点击时自动弹菜单，
        // 收不到按键动作，也就无法为左/右/中键分别绑动作。
        // 改为订阅三种鼠标抬起事件，在 action 里按当前偏好路由。
        button.target = self
        button.action = #selector(statusBarClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
    }

    private func makeStatusMenu() -> NSMenu {
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
        return menu
    }

    /// 状态栏图标点击：按「哪个键 + 当前偏好」路由到对应动作。
    ///
    /// 事件类型与 buttonNumber 的对应：
    /// - 左键 `.leftMouseUp`，buttonNumber 0
    /// - 右键 `.rightMouseUp`，buttonNumber 1（control-click 也会被系统合成成右键）
    /// - 中键 `.otherMouseUp`，buttonNumber 2
    @objc private func statusBarClicked(_ sender: NSStatusBarButton?) {
        guard let button = sender ?? statusItem.button else { return }
        let event = NSApp.currentEvent

        let action: TrayClickAction
        switch event?.buttonNumber {
        case 1:  action = Preferences.shared.trayRightAction
        case 2:  action = Preferences.shared.trayMiddleAction
        default: action = Preferences.shared.trayLeftAction
        }

        switch action {
        case .menu:
            popUpStatusMenu(button)
        case .regionCapture:
            startRegionCapture()
        case .windowCapture:
            startWindowCapture()
        case .history:
            showHistory()
        case .noAction:
            break
        }
    }

    /// 手动弹出状态栏菜单（自动弹菜单的前提 `statusItem.menu` 已被我们弃用）。
    private func popUpStatusMenu(_ button: NSStatusBarButton) {
        button.isHighlighted = true
        // 锚点取按钮左下角、y 抬到按钮上方 2pt，菜单即贴在图标下沿展开，
        // 与系统自动弹菜单的默认位置一致。
        statusMenu.popUp(positioning: nil,
                         at: NSPoint(x: 0, y: button.bounds.height + 2),
                         in: button)
        button.isHighlighted = false
    }

    // MARK: - Actions

    @objc private func startRegionCapture() {
        // 权限预检改成 await（不再用信号量卡主线程）。整个流程挪进 Task：
        // AppKit 的 action 本身跑在主 actor 上，所以这里显式 @MainActor，UI 操作照旧安全。
        Task { @MainActor in
            guard await checkScreenCapturePermission() else {
                showPermissionAlert()
                return
            }
            beginRegionCapture()
        }
    }

    /// 权限通过之后的实际流程（从 `startRegionCapture` 拆出来，便于 async 化）
    private func beginRegionCapture() {
        // 开新截图会把当前标注窗收掉 —— 有未保存的标注时先问一句，**与窗口截图那条路一致**。
        //
        // 这里原来是直接 `annotationWindow?.orderOut(nil)`，有两个后果（同一个洞）：
        //   1. 不问就收 —— 一次快捷键静默丢掉上一张的成果；
        //   2. 只是 orderOut，引用还挂着。用户在新选区按 Esc 取消后，那个窗口
        //      **永远不会再显示出来**；而下次截图 openAnnotationWindow 会把
        //      annotationWindow 指向新窗，旧窗随之释放 —— 内容是真的没了。
        // 改成和窗口截图一样：先确认、再 close()。close() 会触发 onClose，
        // 顺带把冻结覆盖层收干净（原来那段"补收一次"的注释说的就是这个坑）。
        if let window = annotationWindow {
            guard window.confirmDiscardIfNeeded() else { return }
            window.close()
            annotationWindow = nil
        }

        // 覆盖层可能还留着（上一次截图在选区内被中断等），补收一次
        regionSelectionWindow?.hideOverlays()
        regionSelectionWindow = nil

        // 等窗口服务器完成合成，再去冻结屏幕。
        // 这是**一次性**等待，不是每次截图都要付：冻结之后覆盖层显示的是静止画面，
        // 选区确定后只需裁剪冻结图，不再需要「关掉覆盖层 → 等它消失 → 再截图」那一套。
        captureGeneration += 1
        let generation = captureGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.presentRegionSelection(generation: generation)
        }
    }

    private func presentRegionSelection(generation: Int) {
        // 等待这 0.06 秒期间又发起了一次截图 → 这次已经过时，直接不做
        guard generation == captureGeneration else { return }

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
                // 只有"还是当前这一次"才能清引用/报错 —— 否则会把新一次刚建好的覆盖层清掉
                guard generation == self.captureGeneration else { return }
                self.regionSelectionWindow = nil
                self.showCaptureFailureAlert()
                return
            }
            // 冻结期间又发起了一次截图 → 这一份已经无主，自己收干净，不强推上屏
            guard generation == self.captureGeneration else {
                window.hideOverlays()
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
        // 防重入必须在**同步段**占坑：权限预检改成 await 之后，两次快速按键都会在挂起处
        // 溜过守卫，于是调度出两次捕获、第二次覆盖 annotationWindow。
        guard !windowCaptureInFlight else { return }
        windowCaptureInFlight = true

        Task { @MainActor in
            guard await checkScreenCapturePermission() else {
                windowCaptureInFlight = false
                showPermissionAlert()
                return
            }

            // 开新截图会把当前标注窗关掉 —— 有未保存的标注时先问一句，
            // 用户取消就整件事都不做（否则等于用一次菜单点击静默丢掉上一张的成果）
            if let window = annotationWindow {
                guard window.confirmDiscardIfNeeded() else {
                    windowCaptureInFlight = false
                    return
                }
                window.close()
                annotationWindow = nil
            }

            // 给用户一点时间切换到目标窗口
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    defer { self.windowCaptureInFlight = false }
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
        CaptureHistory.shared.record(capture.image, pixelScale: capture.pixelScale,
                                       onFailure: { [weak self] in
            // 写盘失败以前完全静默 —— 用户以为历史都存着，其实一张都没落盘。
            // 提示优先落在标注窗的 HUD 上（那时它通常已经开出来了），拿不到就只剩提示音。
            self?.annotationWindow?.flashHUD("历史记录写入失败")
            NSSound.beep()
        })
    }

    /// 打开标注窗口。
    ///
    /// 逻辑尺寸取捕获方**实测反推**的倍率（`CapturedImage.logicalSize`），
    /// 不再自己读 `backingScaleFactor`：那是"显示侧用屏幕倍率、裁剪侧用反推"的双轨制，
    /// 两者一旦不符（跨屏 / 降级 1x），画布会与选区错位，而这个错位只在真机上才看得见。
    private func openAnnotationWindow(with capture: CapturedImage) {
        let nsImage = NSImage(cgImage: capture.image, size: capture.logicalSize)

        // 把**像素**尺寸显式传下去：导出分辨率必须锚在源截图上，
        // 而不是让 NSImage.lockFocus() 按"当前显示器"猜（1x 屏上会掉一半像素）
        let window = AnnotationWindow(image: nsImage, anchor: capture.anchorRect,
                                      pixelSize: CGSize(width: capture.image.width,
                                                        height: capture.image.height))
        // 标注窗关闭时：AppDelegate 不该再留着它。
        //
        // 少了 `annotationWindow = nil` 这一句，用 X / 「放弃」关掉窗口之后引用还挂着，
        // 于是 ⌘Q 会对着一个**已经消失的窗口**再问一次「放弃这张截图？」——
        // 而那份内容早被用户明确丢弃了，只会让人莫名其妙。
        //
        // 覆盖层的所有权在 regionSelectionWindow 手上，标注窗口只负责通知 ——
        // 这一句只对"区域截图"那条路有意义（窗口截图没有覆盖层）。
        window.onClose = { [weak self] in
            guard let self else { return }
            self.annotationWindow = nil
            if capture.anchorRect != nil {
                self.regionSelectionWindow?.hideOverlays()
                self.regionSelectionWindow = nil
            }
        }

        annotationWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
