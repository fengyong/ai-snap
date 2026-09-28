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
    ///
    /// **按 Z 序逐个试**：最前面那个未必截得动（某些窗口在当前权限/状态下会抛错），
    /// 只试第一个的话就表现为"点了没反应"。全部失败才报没找到。
    static func captureWindowUnderMouse() async throws -> CapturedImage {
        let candidates = windowCandidatesUnderMouse()
        guard !candidates.isEmpty else {
            throw ScreenCaptureError.windowNotFoundUnderMouse
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                let (image, pointWidth) = try await CaptureProviderSCK.captureWindow(windowID: candidate.id)
                guard image.width >= 1, image.height >= 1, pointWidth >= 1 else { continue }
                return CapturedImage(image: image,
                                     pixelScale: CapturedImage.scale(pixelWidth: image.width,
                                                                     pointWidth: pointWidth),
                                     anchorRect: nil)
            } catch {
                lastError = error      // 这个截不动，继续试下一个
            }
        }
        throw lastError ?? ScreenCaptureError.windowNotFoundUnderMouse
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

    /// 返回鼠标下方**所有**可截图的候选窗口，按 Z 序（最前面的在前）。
    ///
    /// 过滤是必须的：只判 `pid != 自己` + 坐标命中的话，会选到 Window Server 的窗口、
    /// 菜单栏、Dock 之类 —— 对它们截图要么抛错、要么返回一张空图，用户看到的就是
    /// "点了窗口截图没反应"。**程序坞尤其阴**：它是 `layer 20`、铺满整个屏幕，
    /// 鼠标停在桌面上时它必然命中。
    ///
    /// 判据只保留 `0 <= layer < 20`：
    ///   · 这一档既包含普通应用窗口（`layer == 0`），也包含**浮动面板 / 画中画**
    ///     （`NSFloatingWindowLevel` = 3 等）。早先只认 `layer == 0` 会把浮层静默跳过，
    ///     于是截到它**后面**那个窗口 —— 用户点的明明是浮窗，拿到的却是别的东西，
    ///     比"没反应"更难察觉。
    ///   · `layer >= 20` 是系统 UI：程序坞 20、菜单栏 24、Window Server 覆盖层
    ///     2147483630；`layer < 0` 是通知中心之类。这些才是该挡掉的。
    ///
    /// **不要**把 `layer == 0` 单独提到前面：那等于放弃 Z 序，浮窗在普通窗口前面时
    /// 反而会去截后面那个 —— 又一次同样的错误。Z 序本身就是正确答案。
    ///
    /// `alpha > 0`（完全透明的截不出东西）与尺寸 ≥ 1×1（零尺寸占位条目）同理。
    ///
    /// 纯函数（只吃窗口信息列表 + 点 + 自身 pid），便于用构造数据直接验证。
    static func windowCandidates(from windowList: [[String: Any]],
                                 at point: CGPoint,
                                 ownPID: Int32) -> [(id: CGWindowID, bounds: CGRect)] {
        var result: [(id: CGWindowID, bounds: CGRect)] = []
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
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
            guard bounds.width >= 1, bounds.height >= 1 else { continue }
            guard bounds.contains(point) else { continue }
            result.append((windowID, bounds))
        }
        return result
    }

    /// 鼠标下方（按 Z 序）的候选窗口
    private static func windowCandidatesUnderMouse() -> [(id: CGWindowID, bounds: CGRect)] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        // CGWindowList 用屏幕坐标（左上原点），NSEvent 用左下原点，这里换算一次
        let mouseLocation = NSEvent.mouseLocation
        let testPoint = CGPoint(x: mouseLocation.x,
                                y: primaryScreenHeight - mouseLocation.y)
        return windowCandidates(from: windowList,
                                at: testPoint,
                                ownPID: ProcessInfo.processInfo.processIdentifier)
    }
}
