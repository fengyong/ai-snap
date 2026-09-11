import Cocoa

/// 截图捕获的统一入口。
///
/// ## 分工
///
/// ```
/// 决定「截哪个」  →  本文件（CGWindowListCopyWindowInfo，未废弃）
/// 真正「抓图」    →  CaptureProviderSCK（ScreenCaptureKit）
/// ```
///
/// 两者通过 `CGWindowID` 对接 —— `SCWindow.windowID` 的类型就是 `CGWindowID`，
/// 所以「鼠标下窗口判定」这段最复杂的 Z 序逻辑可以完全保持不变。
///
/// ## 为什么是异步
///
/// `SCScreenshotManager` 是异步 API。调用方在 `Task { @MainActor in ... }` 中 await，
/// 失败时按 `ScreenCaptureError` 分类处理（例如权限被拒要弹引导）。
///
/// ## 回滚
///
/// 若需要退回旧的 `CGWindowListCreateImage` 实现，把下面两个 `captureXxx` 的函数体
/// 指向 `CaptureProviderLegacy` 即可（该文件已保留完整旧实现），
/// 或直接 `git revert` 本次迁移。注意旧 API 自 macOS 14.0 起 deprecated、15.0 起 obsolete。
enum ScreenCapture {

    // MARK: - 区域截图

    /// 捕获指定屏幕区域。
    ///
    /// `rect` 使用屏幕坐标（左上角原点，Quartz），与旧实现语义一致，
    /// 调用方的坐标换算（`screenHeight - y - height`）无需改动。
    static func captureRegion(_ rect: CGRect) async throws -> CGImage {
        if #available(macOS 15.2, *) {
            // 首选：display-agnostic，原生支持跨多屏，无需构造 filter
            return try await CaptureProviderSCK.captureRegionInRect(rect)
        }
        // macOS 14.0 – 15.1：自行构造 SCContentFilter
        return try await CaptureProviderSCK.captureRegionViaFilter(rect)
    }

    // MARK: - 窗口截图

    /// 捕获鼠标所在位置的窗口。
    static func captureWindowUnderMouse() async throws -> CGImage {
        guard let targetID = windowIDUnderMouse() else {
            throw ScreenCaptureError.windowNotFoundUnderMouse
        }
        return try await CaptureProviderSCK.captureWindow(windowID: targetID)
    }

    // MARK: - 窗口枚举

    // MARK: - 坐标换算

    /// 把一块屏幕的 AppKit 框架转成 Quartz 矩形（左上角原点），用于整屏捕获。
    /// 换算在 `ScreenGeometry.quartzRect`（纯函数，已离屏测试）。
    static func quartzRect(for screen: NSScreen) -> CGRect {
        ScreenGeometry.quartzRect(appKitScreenFrame: screen.frame,
                                  primaryScreenHeight: primaryScreenHeight)
    }

    /// Y 轴翻转的基准高度 = **主显示器**（Quartz 原点所在、`frame.origin == .zero` 的那块）的高度。
    ///
    /// 这里不能用 `NSScreen.main`：它表示「当前 key window 所在屏，无 key window 时为菜单栏所在屏」，
    /// 当标注窗口位于副屏时取值会变，翻转基准随之出错，导致鼠标在副屏时命中到错误的窗口。
    /// macOS 全局坐标系里 AppKit 原点在主显示器左下、Quartz 原点在主显示器左上，
    /// 因此 `quartzY = 主显示器高度 - appKitY` 对所有屏幕都成立。
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    /// 返回鼠标下方最前面、非自身进程的窗口 ID。
    ///
    /// `CGWindowListCopyWindowInfo` 未废弃（`API_AVAILABLE(macos(10.5))`），
    /// 因此这段「按 Z 序遍历 + 坐标命中」的逻辑原样保留，
    /// 唯一的变化是：找到目标后不再自己抓图，而是把 windowID 交给 ScreenCaptureKit。
    private static func windowIDUnderMouse() -> CGWindowID? {
        let mouseLocation = NSEvent.mouseLocation

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // CGWindowList 使用屏幕坐标（左上原点），NSEvent 使用左下原点。整个循环共用一个点，算一次即可。
        let testPoint = CGPoint(x: mouseLocation.x,
                                y: primaryScreenHeight - mouseLocation.y)

        let myPID = ProcessInfo.processInfo.processIdentifier
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid != myPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if bounds.contains(testPoint) {
                return windowID
            }
        }
        return nil
    }
}
