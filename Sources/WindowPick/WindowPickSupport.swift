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

    /// 全部可截窗口的 frame（AppKit 全局坐标，副屏可为负），按 Z 序。
    /// 选区吸附的目标清单用；Quartz→AppKit 翻转与 candidates 同一套公式。
    static func allWindowFrames(from windowList: [[String: Any]],
                                primaryScreenHeight: CGFloat,
                                ownPID: Int32) -> [CGRect] {
        ScreenCapture.windowFrames(from: windowList, ownPID: ownPID).map { hit in
            CGRect(x: hit.bounds.minX,
                   y: primaryScreenHeight - hit.bounds.maxY,
                   width: hit.bounds.width,
                   height: hit.bounds.height)
        }
    }

    /// 滚轮换选的下标步进。与工具栏切换共用 `CyclicIndex` 的回绕语义
    /// （正向到底回开头、反向到头回末尾、空列表给 0），不另写一套取模。
    static func steppedCandidateIndex(current: Int?, count: Int, scrollUp: Bool) -> Int {
        CyclicIndex.step(current, count: count, reverse: scrollUp)
    }
}

// MARK: - 选区窗口吸附

/// 拖拽/微调选区时，把选区四边吸附到最近的窗口边。
///
/// 纯逻辑（不依赖 AppKit）：候选窗口 frame 已由调用方翻成 AppKit 全局坐标
/// （`ScreenCapture.windowFrames` 的调用方做一次翻转），这里只做几何决策。
/// 吸附是「错了不报错、只是差 8 个点」的静默行为，必须能离屏钉死。
enum SelectionSnapping {

    /// 吸附距离阈值（点）。与点吸附（Snapping 的 12pt）同量级。
    static let threshold: CGFloat = 8

    /// 把 `rect`（AppKit 全局坐标）的四边分别尝试吸附到窗口的边。
    ///
    /// 策略：对每个窗口生成一个候选，取「贴上的边数最多」者，并列取位移最小者。
    ///   - **跨边吸附**：选区的每条边与窗口的**两条**边都比较（选区底边贴窗口顶边
    ///     是高频场景 —— 只比对同序边会漏掉一半的可吸场景，实测探针抓到）；
    ///   - **防塌缩**：同一轴的两条边吸到同一目标会把矩形压成零宽/高 —— 该轴放弃吸附。
    /// 返回吸附后的矩形与被吸附的窗口框（nil = 没有可吸附的窗口边，原样返回）。
    static func snapped(_ rect: CGRect,
                        toWindowFrames frames: [CGRect]) -> (rect: CGRect, snappedFrame: CGRect?) {
        guard !frames.isEmpty else { return (rect, nil) }

        var best = rect
        var bestFrame: CGRect?
        var bestEdges = 0
        var bestDisplacement = CGFloat.greatestFiniteMagnitude

        for frame in frames {
            func nearestWithin(_ value: CGFloat, _ targets: [CGFloat]) -> CGFloat {
                var best = value
                for t in targets where abs(value - t) <= threshold {
                    if best == value || abs(t - value) < abs(best - value) { best = t }
                }
                return best
            }

            var newMinX = nearestWithin(rect.minX, [frame.minX, frame.maxX])
            var newMaxX = nearestWithin(rect.maxX, [frame.minX, frame.maxX])
            var newMinY = nearestWithin(rect.minY, [frame.minY, frame.maxY])
            var newMaxY = nearestWithin(rect.maxY, [frame.minY, frame.maxY])
            // 防塌缩：同轴吸到同一点 → 该轴保持原值
            if newMinX == newMaxX { newMinX = rect.minX; newMaxX = rect.maxX }
            if newMinY == newMaxY { newMinY = rect.minY; newMaxY = rect.maxY }

            var edges = 0
            var displacement: CGFloat = 0
            if newMinX != rect.minX { edges += 1; displacement += abs(newMinX - rect.minX) }
            if newMaxX != rect.maxX { edges += 1; displacement += abs(newMaxX - rect.maxX) }
            if newMinY != rect.minY { edges += 1; displacement += abs(newMinY - rect.minY) }
            if newMaxY != rect.maxY { edges += 1; displacement += abs(newMaxY - rect.maxY) }
            let candidate = CGRect(x: newMinX, y: newMinY,
                                   width: newMaxX - newMinX, height: newMaxY - newMinY)

            let better = edges > bestEdges
                || (edges == bestEdges && edges > 0 && displacement < bestDisplacement)
            if better {
                best = candidate
                bestFrame = frame
                bestEdges = edges
                bestDisplacement = displacement
            }
        }
        return (best, bestEdges > 0 ? bestFrame : nil)
    }
}
