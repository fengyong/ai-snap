import Cocoa
import CoreGraphics

/// 一次截图的结果：图像 + 它的来源屏（用于推算逻辑尺寸与标注窗口位置）
struct CaptureResult {
    let image: CGImage
    /// 截图来源屏；窗口截图时是窗口所在屏，区域截图时是拖拽所在屏
    let screen: NSScreen?

    /// 该屏的缩放因子（像素 / 点）
    var scale: CGFloat { screen?.backingScaleFactor ?? 2.0 }

    /// 逻辑尺寸（点）
    var logicalSize: NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

enum ScreenCapture {

    // MARK: - 坐标工具

    /// Quartz（左上角原点，锚定"主显示器"= 菜单栏所在屏）坐标下的主显示器高度。
    ///
    /// 注意术语陷阱：`kCGWindowBounds` 的原点是 **CG 语义的 main display**，
    /// 而 `NSScreen.main` 的语义是 *"Screen with key window"*，两者不是一回事。
    static var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
    }

    /// 鼠标当前所在位置，直接取 Quartz 坐标（已经是左上角原点，无需翻转）
    static var mouseLocationInQuartz: CGPoint {
        if let e = CGEvent(source: nil) { return e.location }
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryDisplayHeight - p.y)
    }

    /// 所有屏幕在 Quartz 坐标下的并集（用于校验截图矩形是否真的落在某块屏上）
    static var screensUnionInQuartz: CGRect {
        let h = primaryDisplayHeight
        return NSScreen.screens.reduce(CGRect.null) { acc, screen in
            let f = screen.frame
            let q = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
            return acc.union(q)
        }
    }

    /// 捕获鼠标所在位置的窗口
    ///
    /// 只考虑普通应用窗口：`layer == 0`、`alpha > 0`、尺寸 ≥ 1×1。
    /// 没有这层过滤时会选到 Window Server / 登录窗口 / 菜单栏 / 控制中心 等，
    /// 而对它们截图会返回 nil，最终表现为"点了菜单毫无反应"。
    /// 从窗口信息列表中筛出"可截图的普通应用窗口"，按前后顺序返回。
    ///
    /// 纯函数，便于用构造数据直接验证过滤条件（见 `probes/probe_screens.swift`）。
    /// 过滤条件：非自身进程、`layer == 0`（普通应用窗口层）、`alpha > 0`、尺寸 ≥ 1×1、鼠标点落在窗口内。
    /// `kCGWindowNumber` 在真实窗口列表里是 CFNumber，不同来源可能桥接成 Int / NSNumber / UInt32，
    /// 这里统一取一次，避免因为严格的 `as? CGWindowID` 漏掉窗口。
    static func windowID(from info: [String: Any]) -> CGWindowID? {
        guard let value = info[kCGWindowNumber as String] else { return nil }
        if let id = value as? CGWindowID { return id }
        if let n = value as? NSNumber { return n.uint32Value }
        if let i = value as? Int { return CGWindowID(i) }
        return nil
    }

    static func windowCandidates(from windowList: [[String: Any]],
                                 at point: CGPoint,
                                 ownPID: Int32) -> [(id: CGWindowID, bounds: CGRect)] {
        var result: [(id: CGWindowID, bounds: CGRect)] = []
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowID = windowID(from: info) else {
                continue
            }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.width >= 1, bounds.height >= 1 else { continue }
            guard bounds.contains(point) else { continue }
            result.append((windowID, bounds))
        }
        return result
    }

    static func captureWindowUnderMouse() -> CaptureResult? {
        let testPoint = mouseLocationInQuartz

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let candidates = windowCandidates(from: windowList,
                                          at: testPoint,
                                          ownPID: ProcessInfo.processInfo.processIdentifier)
        for candidate in candidates {
            guard let image = CGWindowListCreateImage(
                candidate.bounds, .optionIncludingWindow, candidate.id,
                [.boundsIgnoreFraming, .bestResolution]
            ), !isFullyTransparent(image) else {
                continue     // 有些窗口声明了 bounds 却取不到像素，继续试下一个
            }
            return CaptureResult(image: image, screen: screenContainingQuartzRect(candidate.bounds))
        }
        return nil
    }

    /// 捕获指定屏幕区域（rect 为 Quartz 坐标）
    ///
    /// - Parameter belowWindow: 需要排除的窗口号（通常是选区覆盖层自身）。
    ///   传入后无需"先隐藏窗口再 sleep 等它消失"，可以直接截到覆盖层之下的真实内容。
    static func captureRegion(_ rect: CGRect, belowWindow: CGWindowID? = nil) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        // 坐标算错时 CGWindowListCreateImage 会返回一张合法的全透明图而不报错，
        // 这里先自己校验矩形是否与任何一块屏相交。
        guard screensUnionInQuartz.intersects(rect) else { return nil }

        if let win = belowWindow {
            if let image = CGWindowListCreateImage(
                rect, .optionOnScreenBelowWindow, win, [.bestResolution]
            ), !isFullyTransparent(image) {
                return image
            }
        }
        // 回退：不做 below-window 排除，会把覆盖层自身也拍进去。
        // **调用方必须先撤掉自己的覆盖窗口**再走这条路
        // （见 RegionSelectionWindow.finishSelection）。
        return CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, kCGNullWindowID, [.bestResolution])
    }

    /// 判断图像是否完全透明（用于识别"截到了空白"）
    static func isFullyTransparent(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        // 注意**不能**写成 `w > 1, h > 1`：权限兜底探测用的就是 1pt×1pt 的极小截图，
        // 在 1x 屏上它正好是 1×1 像素，会被直接判成"全透明"，
        // 于是 hasScreenCapturePermission 恒为 false（怎么授权都进不去）。
        guard w > 0, h > 0 else { return true }
        let sampleW = min(w, 32), sampleH = min(h, 32)
        var buffer = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        guard let ctx = CGContext(data: &buffer, width: sampleW, height: sampleH,
                                  bitsPerComponent: 8, bytesPerRow: sampleW * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        for i in stride(from: 3, to: buffer.count, by: 4) where buffer[i] != 0 { return false }
        return true
    }

    /// 找出 Quartz 矩形所在的屏
    static func screenContainingQuartzRect(_ rect: CGRect) -> NSScreen? {
        let h = primaryDisplayHeight
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { screen in
            let f = screen.frame
            let q = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
            return q.contains(center)
        }
    }
}
