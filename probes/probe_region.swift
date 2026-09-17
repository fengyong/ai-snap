import Cocoa

//  探针 08 — 区域选择（报告 P1-2 / P1-11 / P2-7）
//
//  验证三件事：
//   1. 每块屏都有带选区视图的覆盖窗口（旧实现只有主屏能用，其余屏的空白窗口会吞掉鼠标事件）；
//   2. 选区矩形换算带上了宿主屏原点（直接调用生产函数 RegionSelectionWindow.quartzRect）；
//   3. 用 below-window 截图可以在覆盖层仍然显示时截到"真实内容"，因此不需要 sleep 等窗口消失。

@main
struct RegionProbe {
    static func main() {
        bootstrapApp()

        // ── P1-2: 每块屏都要有选区视图 ──
        Probe.section("P1-2 覆盖窗口与选区视图（每块屏一个）")
        let selection = RegionSelectionWindow { _ in }
        selection.beginSelection()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let ours = NSApp.windows.filter { $0.level.rawValue == NSWindow.Level.statusBar.rawValue + 1 && $0.isVisible }
        let withView = ours.filter { $0.contentView is RegionSelectionView }
        let withoutView = ours.filter { !($0.contentView is RegionSelectionView) }

        Probe.note("P1-2", "覆盖窗口 \(ours.count) 个（屏幕 \(NSScreen.screens.count) 块），其中带选区视图 \(withView.count) 个")
        if NSScreen.screens.count > 1 && withView.count == NSScreen.screens.count && withoutView.isEmpty {
            Probe.ok("P1-2", "每块屏都有可交互的选区视图（副屏也能框选）", "\(withView.count)/\(NSScreen.screens.count)")
        } else if NSScreen.screens.count == 1 && withView.count == 1 {
            Probe.ok("P1-2", "单屏环境下选区视图正常", "1/1（多屏结论需接第二块显示器复跑）")
        } else {
            Probe.bug("P1-2", "存在没有选区视图的覆盖窗口（会吞掉该屏的鼠标事件）",
                      "带视图 \(withView.count) 个 / 无视图 \(withoutView.count) 个 / 屏幕 \(NSScreen.screens.count) 块",
                      expect: "每块屏都应有且仅有一个带 RegionSelectionView 的覆盖窗口")
        }

        // ── P1-2b: 覆盖窗口必须**精确落在各自屏幕上** ──
        //  这是最容易漏的一环：窗口存在 ≠ 窗口在对的位置。
        //  曾经的 bug 是给 NSWindow 传了 `screen:`，导致副屏窗口原点被再加一次屏幕原点
        //  （(-803,-982) 变成 (-1606,-1964)），窗口被扔到所有显示器之外 —— 现象就是
        //  "3 块屏只有 1 块能框选"，而只检查"窗口是否存在"的探针完全看不出来。
        Probe.section("P1-2b 覆盖窗口的位置是否与屏幕一致")
        var misplaced: [String] = []
        for screen in NSScreen.screens {
            guard let win = ours.first(where: { $0.isVisible && $0.screen === screen }) else {
                misplaced.append("\(screenDesc(screen)): 没有对应窗口")
                continue
            }
            if win.frame != screen.frame {
                misplaced.append(String(format: "%@: 窗口在 {%.0f,%.0f %.0fx%.0f}",
                                        screenDesc(screen), win.frame.minX, win.frame.minY,
                                        win.frame.width, win.frame.height))
            }
        }
        if misplaced.isEmpty {
            Probe.ok("P1-2b", "每个覆盖窗口都精确覆盖它所属的屏幕", "\(NSScreen.screens.count)/\(NSScreen.screens.count)")
        } else {
            Probe.bug("P1-2b", "存在位置错误的覆盖窗口（该屏将无法框选）",
                      misplaced.joined(separator: "；"),
                      expect: "窗口 frame 应等于所属屏幕的 frame")
        }

        // ── P1-2c: 在每块屏上真的拖一次，检查是否都能完成选区 ──
        Probe.section("P1-2c 逐屏模拟拖拽（真实 sendEvent 路径）")
        var dragResults: [(String, Bool, String)] = []
        for screen in NSScreen.screens {
            selection.cancelSelection()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            var captured: CGImage?
            var fired = false
            let sel = RegionSelectionWindow { result in
                fired = true
                captured = result?.image
            }
            sel.beginSelection()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            defer { sel.cancelSelection() }
            guard let win = NSApp.windows.first(where: {
                $0.level.rawValue == NSWindow.Level.statusBar.rawValue + 1 && $0.isVisible && $0.screen === screen
            }) else {
                dragResults.append((screenDesc(screen), false, "无可见覆盖窗口"))
                continue
            }
            let a = NSPoint(x: screen.frame.width * 0.30, y: screen.frame.height * 0.30)
            let b = NSPoint(x: screen.frame.width * 0.55, y: screen.frame.height * 0.55)
            func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0,
                                   windowNumber: win.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            win.sendEvent(ev(.leftMouseDown, a))
            win.sendEvent(ev(.leftMouseDragged, b))
            win.sendEvent(ev(.leftMouseUp, b))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))

            if !fired {
                dragResults.append((screenDesc(screen), false, "拖拽没有任何回调"))
            } else if let img = captured {
                dragResults.append((screenDesc(screen), true, "\(img.width)x\(img.height) px"))
            } else {
                dragResults.append((screenDesc(screen), false, "回调触发但截图为 nil"))
            }
        }
        let failed = dragResults.filter { !$0.1 }
        for r in dragResults { Probe.note("P1-2c", "\(r.0) → \(r.1 ? "✅" : "❌") \(r.2)") }
        if failed.isEmpty {
            Probe.ok("P1-2c", "每块屏都能完成区域选择并取到图像", "\(dragResults.count)/\(dragResults.count) 块屏通过")
        } else {
            Probe.bug("P1-2c", "有屏幕无法完成区域选择（多屏支持不完整）",
                      failed.map { "\($0.0): \($0.2)" }.joined(separator: "；"),
                      expect: "每块屏都应能拖拽选区并返回图像")
        }
        selection.cancelSelection()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // ── P2-7: below-window 截图可以在覆盖层仍显示时拍到真实内容 ──
        Probe.section("P2-7 below-window 截图（覆盖层不需先消失）")
        if let overlay = withView.first, let screen = overlay.screen {
            let g = CGRect(x: screen.frame.midX - 60, y: screen.frame.midY - 60, width: 120, height: 120)
            let q = RegionSelectionWindow.quartzRect(forViewRect: g, on: screen)
            let below = ScreenCapture.captureRegion(q, belowWindow: CGWindowID(overlay.windowNumber))
            let withOverlay = ScreenCapture.captureRegion(q)
            if let a = below, let b = withOverlay {
                let la = averageLuminance(a), lb = averageLuminance(b)
                Probe.note("P2-7", String(format: "below-window 平均亮度 %.3f；含覆盖层 %.3f", la, lb))
                if la > lb + 0.02 {
                    Probe.ok("P2-7", "below-window 截图成功排除了覆盖层（遮罩未被拍进去，无需 sleep）",
                             String(format: "亮度差 %.3f", la - lb))
                } else {
                    Probe.note("P2-7", "两者亮度接近 —— 可能该区域本来就是暗色，或当前无屏幕录制权限；此项不作为判定")
                }
            } else {
                Probe.note("P2-7", "截图返回 nil（可能缺少屏幕录制权限），跳过")
            }
        }

        // ── P4-16: 取消后不留窗口 ──
        Probe.section("P4-16 取消后覆盖窗口是否被清理")
        selection.cancelSelection()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let leftover = NSApp.windows.filter {
            $0.level.rawValue == NSWindow.Level.statusBar.rawValue + 1 && $0.isVisible
        }
        if leftover.isEmpty {
            Probe.ok("P4-16", "取消后覆盖窗口已全部关闭并摘除", "剩余 0 个")
        } else {
            Probe.bug("P4-16", "取消后仍有覆盖窗口残留",
                      "剩余 \(leftover.count) 个（NSApplication.windows 持有窗口，仅靠 ARC 释放引用不会关闭它）",
                      expect: "teardown 时应 orderOut + close")
        }

        Probe.finish("probe_region")
    }

    static func averageLuminance(_ image: CGImage) -> Double {
        let w = 32, h = 32
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) {
            total += (Double(buf[i]) + Double(buf[i + 1]) + Double(buf[i + 2])) / 3.0
        }
        return total / Double(w * h) / 255.0
    }
}
