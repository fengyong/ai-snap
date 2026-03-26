import Cocoa
import CoreGraphics

enum ScreenCapture {

    /// 捕获鼠标所在位置的窗口
    static func captureWindowUnderMouse() -> CGImage? {
        let mouseLocation = NSEvent.mouseLocation

        // 获取所有窗口信息
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // 找到鼠标下方最前面的非自身窗口
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

            // CGWindowList 使用屏幕坐标（左上角原点），NSEvent 使用左下角原点
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let flippedY = screenHeight - mouseLocation.y
            let testPoint = CGPoint(x: mouseLocation.x, y: flippedY)

            if bounds.contains(testPoint) {
                return CGWindowListCreateImage(
                    bounds,
                    .optionIncludingWindow,
                    windowID,
                    [.boundsIgnoreFraming, .bestResolution]
                )
            }
        }
        return nil
    }

    /// 捕获指定屏幕区域
    static func captureRegion(_ rect: CGRect) -> CGImage? {
        return CGWindowListCreateImage(
            rect,
            .optionOnScreenBelowWindow,
            kCGNullWindowID,
            [.bestResolution]
        )
    }
}
