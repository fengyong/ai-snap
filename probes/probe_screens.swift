import Cocoa
import CoreGraphics

//  探针 07 — 屏幕坐标系与窗口挑选（报告 P1-1 / P1-3 / P1-10 / P1-12 / P2-6）
//
//  ⚠️ 本探针的结论分两类：
//     · 代码缺陷（用 NSScreen.main 当坐标锚点 / 不过滤窗口层级）— 由 SDK 文档即可判定，与会话无关
//     · 具体数值（偏移多少 pt、挑中哪个窗口）— 依赖当前会话状态，锁屏/休眠时会失真
//  因此本探针把"实测值"和"应有值"都打印出来，请在有交互的正常会话下再跑一次对照。

@main
struct ScreensProbe {
    static func main() {
        bootstrapApp()
        let mouse = NSEvent.mouseLocation

        // ── P1-12 / P1-1：验证"生产代码不再把 NSScreen.main 当坐标锚点" ──
        //  说明：NSScreen.main 与主显示器是否恰好相同，取决于会话状态（key window 在哪块屏），
        //  所以不能用"NSScreen.main == 主屏"作为判定 —— 那是在测环境，不是在测代码。
        //  正确的判定是：① 生产代码里不再出现该用法；② 坐标换算与 CGEvent 的真值一致。
        Probe.section("P1-12 生产代码中的 NSScreen.main 使用")
        let criticalFiles = ["Sources/ScreenCapture.swift", "Sources/RegionSelectionWindow.swift"]
        var offenders: [String] = []
        for file in criticalFiles {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                Probe.note("P1-12", "读不到 \(file)（请在仓库根目录运行本探针）")
                continue
            }
            let hits = text.split(separator: "\n").enumerated().filter { _, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && t.contains("NSScreen.main")
            }
            if !hits.isEmpty {
                offenders.append("\(file):" + hits.map { "\($0.offset + 1)" }.joined(separator: ","))
            }
        }
        if offenders.isEmpty {
            Probe.ok("P1-12", "截图/选区路径中已无 NSScreen.main", "ScreenCapture.swift 与 RegionSelectionWindow.swift 均为 0 处")
        } else {
            Probe.bug("P1-12", "截图/选区路径重新引入了 NSScreen.main（CG 的 main display ≠ NSScreen.main）",
                      offenders.joined(separator: "；"),
                      expect: "坐标锚点应用 CGDisplayBounds(CGMainDisplayID()) 或 frame.origin == .zero 的主屏")
        }
        if let m = NSScreen.main, let p = NSScreen.screens.first {
            Probe.note("P1-12", "当前会话：NSScreen.main = \(screenDesc(m))，主显示器 = \(screenDesc(p))"
                       + (m === p ? "（恰好相同）" : "（不同 —— 旧代码此刻就会算错）"))
        }

        Probe.section("P1-1 鼠标坐标换算是否与 CGEvent 真值一致")
        let probeMouse = NSEvent.mouseLocation
        Probe.note("P1-1", String(format: "NSEvent.mouseLocation = (%.0f, %.0f)", probeMouse.x, probeMouse.y))
        if let cg = CGEvent(source: nil)?.location {
            let converted = ScreenCapture.mouseLocationInQuartz
            let dev = hypot(converted.x - cg.x, converted.y - cg.y)
            if dev < 0.5 {
                Probe.ok("P1-1", "ScreenCapture.mouseLocationInQuartz 与 CGEvent 位置一致（不再手工翻转）",
                         String(format: "(%.0f, %.0f) vs (%.0f, %.0f)", converted.x, converted.y, cg.x, cg.y))
            } else {
                Probe.bug("P1-1", "鼠标坐标换算与 CGEvent 真值不一致",
                          String(format: "偏差 %.1f pt", dev),
                          expect: "应直接使用 Quartz 坐标，偏差 0")
            }
            // 旧算法会偏多少（仅作说明）
            let legacyY = (NSScreen.main?.frame.height ?? 0) - probeMouse.y
            Probe.note("P1-1", String(format: "若仍按旧算法（NSScreen.main 高度翻转）会算出 y=%.0f，偏差 %.0f pt",
                                      legacyY, legacyY - cg.y))
        } else {
            Probe.note("P1-1", "拿不到 CGEvent 位置，跳过")
        }
        let anchorDelta = abs(ScreenCapture.primaryDisplayHeight - CGFloat(CGDisplayBounds(CGMainDisplayID()).height))
        if anchorDelta < 0.5 {
            Probe.ok("P1-1b", "primaryDisplayHeight 等于 CG 语义主显示器高度",
                     String(format: "%.0f", ScreenCapture.primaryDisplayHeight))
        } else {
            Probe.bug("P1-1b", "primaryDisplayHeight 与 CGMainDisplayID 高度不一致",
                      String(format: "偏差 %.0f pt", anchorDelta), expect: "应相等")
        }

        // ── P1-10: 窗口挑选过滤（对真实的纯函数喂构造数据）──
        Probe.section("P1-10 窗口挑选过滤条件")

        func win(pid: Int32, layer: Int, alpha: Double, w: CGFloat, h: CGFloat,
                 x: CGFloat = 0, y: CGFloat = 0, id: Int) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: alpha,
             kCGWindowNumber as String: id,
             kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h]]
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let synthetic: [[String: Any]] = [
            win(pid: 999, layer: 2147483646, alpha: 1, w: 2560, h: 1080, id: 1),
            win(pid: 998, layer: 2001, alpha: 1, w: 30000, h: 30000, x: -15000, y: -15000, id: 2),
            win(pid: 997, layer: 25, alpha: 1, w: 74, h: 33, id: 3),
            win(pid: 996, layer: 0, alpha: 0, w: 800, h: 600, id: 4),
            win(pid: 995, layer: 0, alpha: 1, w: 0, h: 0, id: 5),
            win(pid: ownPID, layer: 0, alpha: 1, w: 800, h: 600, id: 6),
            win(pid: 994, layer: 0, alpha: 1, w: 400, h: 300, x: 100, y: 100, id: 7),
        ]
        let picked = ScreenCapture.windowCandidates(from: synthetic, at: CGPoint(x: 200, y: 200), ownPID: ownPID)
        if picked.count == 1 && picked[0].id == 7 {
            Probe.ok("P1-10", "窗口挑选只接受普通应用窗口", "7 个构造窗口中只剩 1 个合法候选（id=7）")
        } else {
            Probe.bug("P1-10", "窗口挑选过滤条件不正确",
                      "候选 id = \(picked.map { $0.id })（期望 [7]）",
                      expect: "只保留 layer==0 && alpha>0 && 尺寸≥1 && 非自身 的窗口")
        }

        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let real = ScreenCapture.windowCandidates(from: list, at: ScreenCapture.mouseLocationInQuartz, ownPID: ownPID)
            Probe.note("P1-10b", "真实会话中鼠标下方的合法候选 = \(real.count) 个" + (real.first.map { "，最前面 bounds=\($0.bounds)" } ?? ""))
        }

        Probe.section("坐标错误时的失败模式：越界矩形")
        let off = ScreenCapture.captureRegion(CGRect(x: -5000, y: -5000, width: 300, height: 200))
        if let o = off {
            let rep = NSBitmapImageRep(cgImage: o)
            let alpha = rep.colorAt(x: 150, y: 100)?.alphaComponent ?? -1
            if alpha == 0 {
                Probe.bug("P2-6b", "越界矩形截图返回一张全透明的合法图片（坐标算错不会报错，只会得到空白画布）",
                          String(format: "%dx%d，中心 alpha = %.2f", o.width, o.height, alpha),
                          expect: "应对全透明/空白结果做校验并报错")
            } else {
                Probe.ok("P2-6b", "越界矩形截图未返回空白图", String(format: "alpha = %.2f", alpha))
            }
        } else {
            Probe.ok("P2-6b", "越界矩形截图返回 nil（有明确的失败信号）", "nil")
        }

        // ── P1-3: 标注窗口的定位依据 ──
        Probe.section("P1-3 标注窗口按 NSScreen.main 计算尺寸与位置")
        let frame = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        Probe.note("P1-3", String(format: "标注窗口现在按「捕获屏」的 visibleFrame 定位（无捕获屏时退回主显示器）= %@", "\(frame)"))
        Probe.note("P1-3", "同一时刻的鼠标所在屏 = \(screenDesc(NSScreen.screens.first { $0.frame.contains(mouse) }))")
        Probe.note("P1-3", "→ 若两者不是同一块屏，标注窗口会出现在与截图来源无关的显示器上（请在有交互的会话下对照）")

        Probe.finish("probe_screens")
    }
}
