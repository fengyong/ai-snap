import CoreGraphics
import Foundation

/// 截图失败的结构化原因。
///
/// 相比旧实现「抓不到就返回 nil」，调用方可以据此区分「用户拒绝了权限」
/// 和「其他失败」，从而给出正确的引导而不是静默无反应。
enum ScreenCaptureError: Error {
    /// 用户拒绝了屏幕录制权限（对应 SCStreamErrorCode -3801 / -3803）
    case permissionDenied
    /// 找不到覆盖指定矩形的显示器（多屏边界情况）
    case noDisplayForRect(CGRect)
    /// 鼠标下方没有可捕获的窗口
    case windowNotFoundUnderMouse
    /// 其他捕获失败
    case captureFailed(Error)

    /// 需要向用户展示的提示文案；返回 nil 表示静默失败（与旧行为保持一致）
    var userMessage: String? {
        switch self {
        case .permissionDenied:
            return "AISnap 需要屏幕录制权限才能截图。\n\n请前往 系统设置 → 隐私与安全性 → 屏幕录制，启用 AISnap 后重试。"
        case .noDisplayForRect, .windowNotFoundUnderMouse, .captureFailed:
            return nil
        }
    }
}

extension ScreenCaptureError: CustomStringConvertible {
    var description: String {
        switch self {
        case .permissionDenied:
            return "permissionDenied"
        case .noDisplayForRect(let rect):
            return "noDisplayForRect(\(rect))"
        case .windowNotFoundUnderMouse:
            return "windowNotFoundUnderMouse"
        case .captureFailed(let error):
            return "captureFailed(\(error))"
        }
    }
}
