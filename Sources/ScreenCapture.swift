import Cocoa

/// 一次截图的结果：图像 + 它对应的「点 → 像素」倍率（可选的就地选区）。
///
/// ## 为什么倍率要跟图像一起返回
///
/// 标注窗口需要把图像包成 `NSImage` 并声明它的**逻辑尺寸**。原先显示侧自己取
/// `NSScreen.main.backingScaleFactor`，而裁剪侧是按实际尺寸反推的 ——
/// **两条路各算各的**。一旦捕获返回的分辨率与屏幕倍率不一致（跨屏、降到 1x、
/// 或者 SCK 的行为随版本变化），裁出来的图像素会与预期不符，画布就缩成选区的一半，
/// 而"画布正好压在选区上"这个刻意做出来的观感会当场崩掉。
///
/// 现在倍率由捕获方**按实际尺寸反推**、随图像一起往下传，两侧永远一致 ——
/// 把"碰巧正确"变成"构造性正确"。（这条是第四批评审的未修项。）
struct CapturedImage {
    let image: CGImage
    /// 图像像素宽 ÷ 逻辑点宽。实测反推，不取 `backingScaleFactor`。
    let pixelScale: CGFloat
    /// 区域截图时选区在 AppKit 屏幕坐标下的矩形（就地编辑要把画布压回这里）；
    /// 窗口截图没有这个概念，为 nil。
    let anchorRect: NSRect?

    /// 逻辑尺寸（点）：标注窗口按它建画布。
    var logicalSize: NSSize {
        NSSize(width: CGFloat(image.width) / max(pixelScale, 0.01),
               height: CGFloat(image.height) / max(pixelScale, 0.01))
    }

    /// 由「图像像素尺寸」与「对应的逻辑点尺寸」反推倍率。
    ///
    /// 点尺寸为 0（理论上不该发生）时退回 1，避免除零把画布尺寸变成无穷大。
    static func scale(pixelWidth: Int, pointWidth: CGFloat) -> CGFloat {
        guard pointWidth > 0 else { return 1 }
        return CGFloat(pixelWidth) / pointWidth
    }
}

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
    ///
    /// 倍率按「图像像素宽 ÷ 窗口逻辑宽」反推 —— 窗口的 `frame` 是点，
    /// 而捕获时配置的像素宽是 `frame.width × pointPixelScale`，两者相除恰好是实际倍率。
    static func captureWindowUnderMouse() async throws -> CapturedImage {
        guard let targetID = windowIDUnderMouse() else {
            throw ScreenCaptureError.windowNotFoundUnderMouse
        }
        let (image, pointWidth) = try await CaptureProviderSCK.captureWindow(windowID: targetID)
        return CapturedImage(image: image,
                             pixelScale: CapturedImage.scale(pixelWidth: image.width,
                                                             pointWidth: pointWidth),
                             anchorRect: nil)
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
