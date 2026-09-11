import Cocoa

/// 旧捕获实现的备份（`CGWindowListCreateImage`）。
///
/// **保留目的**：迁移期间的回滚通道。
///
/// **状态说明**：该 API 在 CoreGraphics 头文件中标记为
/// `SCREEN_CAPTURE_OBSOLETE(10.5, 14.0, 15.0)`，即
/// 引入于 10.5、废弃于 14.0、15.0 起 obsolete。
/// 本项目部署目标为 macOS 14.0，因此此处调用只产生 deprecation warning 而非编译错误。
///
/// 如需回滚：把 `ScreenCapture` 的实现指向本文件，或直接 `git revert` 迁移提交。
/// 计划在下一个大版本删除本文件。
enum CaptureProviderLegacy {

    /// 捕获指定屏幕区域（旧实现）。
    @available(macOS, deprecated: 14.0,
               message: "Legacy 回滚通道；正式路径请使用 CaptureProviderSCK")
    static func captureRegion(_ rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(
            rect,
            .optionOnScreenBelowWindow,
            kCGNullWindowID,
            [.bestResolution]
        )
    }

    /// 按窗口 ID 捕获窗口（旧实现）。
    @available(macOS, deprecated: 14.0,
               message: "Legacy 回滚通道；正式路径请使用 CaptureProviderSCK")
    static func captureWindow(windowID: CGWindowID) -> CGImage? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], windowID
        ) as? [[String: Any]],
            let boundsDict = info.first?[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }

        let bounds = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )

        return CGWindowListCreateImage(
            bounds,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }
}
