import Cocoa

/// 窗口选择模式的纯逻辑。
///
/// 刻意与 GUI 分离：候选筛选、坐标翻转、滚轮换选都是「错了不报错、只是选错窗口」
/// 的静默错误，必须能离屏用合成数据验证。筛选规则**复用** `ScreenCapture.windowCandidates`
/// （layer / alpha / 尺寸判据只有一份，避免两处漂移），本文件只补两件事：
/// 把 Quartz 矩形翻回 AppKit 全局坐标、把窗口标题备好。
enum WindowPickSupport {

    struct Candidate: Equatable {
        let id: CGWindowID
        /// 窗口 frame，**AppKit 全局坐标**（左下原点；副屏可为负 —— 位于主屏上方的
        /// 屏幕 y 可超过主屏高度，位于左侧的屏 x 为负，都不要取绝对值）。
        let frame: CGRect
        /// 「窗口名 — 应用名」；两者缺其一时取另一个，都空则为空串
        /// （显示端给「未命名窗口」兜底文案）。
        let title: String
    }

    /// 光标处（AppKit 全局坐标）的候选窗口，按 Z 序（最前在前）。
    ///
    /// 坐标翻转与 `windowCandidatesUnderMouse` 同一套公式：AppKit 原点在主显示器
    /// 左下、Quartz 原点在主显示器左上，`quartzY = 主屏高 − appKitY` 对所有屏幕成立。
    static func candidates(from windowList: [[String: Any]],
                           at appKitPoint: CGPoint,
                           primaryScreenHeight: CGFloat,
                           ownPID: Int32) -> [Candidate] {
        let quartzPoint = CGPoint(x: appKitPoint.x,
                                  y: primaryScreenHeight - appKitPoint.y)
        return ScreenCapture.windowCandidates(from: windowList, at: quartzPoint, ownPID: ownPID)
            .map { hit in
                let info = windowList.first {
                    ($0[kCGWindowNumber as String] as? CGWindowID) == hit.id
                }
                let parts = [info?[kCGWindowName as String] as? String,
                             info?[kCGWindowOwnerName as String] as? String]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                return Candidate(
                    id: hit.id,
                    frame: CGRect(x: hit.bounds.minX,
                                  y: primaryScreenHeight - hit.bounds.maxY,
                                  width: hit.bounds.width,
                                  height: hit.bounds.height),
                    title: parts.joined(separator: " — "))
            }
    }

    /// 滚轮换选的下标步进。与工具栏切换共用 `CyclicIndex` 的回绕语义
    /// （正向到底回开头、反向到头回末尾、空列表给 0），不另写一套取模。
    static func steppedCandidateIndex(current: Int?, count: Int, scrollUp: Bool) -> Int {
        CyclicIndex.step(current, count: count, reverse: scrollUp)
    }
}
