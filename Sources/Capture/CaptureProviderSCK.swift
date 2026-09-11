import Cocoa
import CoreVideo
import ScreenCaptureKit

/// ScreenCaptureKit 捕获实现。
///
/// 最低要求 macOS 14.0（`SCScreenshotManager` 的引入版本）。
/// 区域截图按系统版本走两条路径：
///   - macOS 15.2+  ：`captureImage(in:)`，直接吃屏幕坐标矩形，原生支持跨多屏
///   - macOS 14.0+  ：`SCContentFilter` + `sourceRect`，需自己换算坐标与像素尺寸
///
/// 窗口截图统一走 `SCContentFilter(desktopIndependentWindow:)`。
enum CaptureProviderSCK {

    // MARK: - 区域截图 · macOS 15.2+（首选路径）

    /// 一步到位截取屏幕上的一个矩形。
    ///
    /// 头文件原文注释：*"the rect for the region in points on the screen space for the
    /// screen shot, this is display agnostic and supports multiple displays"*
    @available(macOS 15.2, *)
    static func captureRegionInRect(_ rect: CGRect) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(in: rect)
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - 区域截图 · macOS 14.0 – 15.1（降级路径）

    static func captureRegionViaFilter(_ rect: CGRect) async throws -> CGImage {
        let content = try await shareableContent()

        // ⚠️ 已知限制：跨屏矩形只取「第一个相交的显示器」，因此 sourceRect 会越界。
        //    当前区域选择只在单屏（主屏）交互，不会触发；将来做多屏交互时，
        //    需要按屏拆分矩形、分别捕获后再拼接（`captureImage(in:)` 在 macOS 15.2+
        //    虽然宣称支持多屏，但实测跨屏时会降级到 1x 分辨率，同样不可直接使用）。
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
            throw ScreenCaptureError.noDisplayForRect(rect)
        }

        // 排除自身进程的窗口（覆盖层等），语义上对齐旧的 .optionOnScreenBelowWindow
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }

        // display 过滤器的 includeMenuBar 默认为 YES，且会包含桌面与 Dock，
        // 与旧的「截屏幕上内容」语义一致。
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // 全局屏幕坐标 → 该 display 的本地逻辑坐标（sourceRect 的单位是「点」）
        config.sourceRect = CGRect(
            x: rect.minX - display.frame.minX,
            y: rect.minY - display.frame.minY,
            width: rect.width,
            height: rect.height
        )

        // ★ 必须显式设置，否则会落到默认的 1920×1080（Retina 陷阱）
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - 窗口截图

    /// 按 CGWindowID 捕获单个窗口。
    ///
    /// `SCWindow.windowID` 的类型就是 `CGWindowID`，所以可以和
    /// `CGWindowListCopyWindowInfo` 的结果直接按 ID 对接。
    ///
    /// 返回「图像 + 窗口的逻辑宽度（点）」：调用方据此**反推**实际倍率，
    /// 而不是另外去取 `backingScaleFactor`（原因见 `CapturedImage`）。
    static func captureWindow(windowID: CGWindowID)
        async throws -> (image: CGImage, pointWidth: CGFloat) {
        // 过滤条件对齐旧代码的 [.optionOnScreenOnly, .excludeDesktopElements]
        let content = try await shareableContent(excludingDesktopWindows: true,
                                                 onScreenWindowsOnly: true)

        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureError.windowNotFoundUnderMouse
        }

        return try await captureWindow(window)
    }

    /// 直接对已取得的 `SCWindow` 截图（自检工具也会用到）。
    static func captureWindow(_ window: SCWindow)
        async throws -> (image: CGImage, pointWidth: CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.ignoreShadowsSingleWindow = true // 等价于旧实现的 .boundsIgnoreFraming

        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return (image, window.frame.width)
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - 对外暴露的辅助（供自检与调试使用）

    /// 取得可捕获内容。
    ///
    /// 参数与 `CGWindowListCopyWindowInfo` 的过滤选项保持语义对齐：
    ///   - 区域截图：`excludingDesktopWindows: false`（需要桌面内容）+ 仅屏幕上的窗口
    ///   - 窗口截图：`excludingDesktopWindows: true`（对齐旧代码的 `.excludeDesktopElements`）
    ///
    /// 注：本 Swift 名称已用 `swiftc -typecheck` 实测确认可用。
    static func shareableContent(excludingDesktopWindows: Bool = false,
                                 onScreenWindowsOnly: Bool = true) async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                excludingDesktopWindows, onScreenWindowsOnly: onScreenWindowsOnly
            )
        } catch {
            throw mapError(error)
        }
    }

    /// 把 `SCStreamError.Code` 映射成可操作的语义错误。
    ///
    /// 注意：Swift 把 SCError.h 里的 `NS_ERROR_ENUM(SCStreamErrorDomain, SCStreamErrorCode)`
    /// 导入为嵌套类型 `SCStreamError.Code`（已用编译器实测确认）。
    static func mapError(_ error: Error) -> ScreenCaptureError {
        let ns = error as NSError
        guard ns.domain == SCStreamErrorDomain,
              let code = SCStreamError.Code(rawValue: ns.code) else {
            return .captureFailed(error)
        }
        switch code {
        case .userDeclined, .missingEntitlements:
            return .permissionDenied
        default:
            return .captureFailed(error)
        }
    }
}
