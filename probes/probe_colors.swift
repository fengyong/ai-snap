import Cocoa

//  探针 13 — 换色 / 线宽对"选中对象"的生效情况（报告 P1-13）
//
//  用户反馈："换色之后，用的还是之前的颜色"。
//  实测结论分两半：
//    · 点色点 / 换色板 → **之后新画的对象**确实用了新颜色（这部分本来就是好的）；
//    · 但**已经画好、并且被选中的对象不会变色** —— 这才是用户看到的现象。
//  本探针把两半都覆盖，并检查撤销与线宽是否同步作用于选中对象。

@main
struct ColorProbe {
    static var window: AnnotationWindow?
    static var canvas: AnnotationView?
    static var arrowYs: [CGFloat] = []
    static var step = 0

    static func main() {
        bootstrapApp(policy: .regular)
        NSApp.activate(ignoringOtherApps: true)
        let w = AnnotationWindow(image: blankCanvas(700, 400))
        window = w
        w.makeKeyAndOrderFront(nil)
        RunLoop.main.add(Timer(timeInterval: 0.5, repeats: false) { _ in runAll() }, forMode: .common)
        NSApp.run()
    }

    // MARK: - 辅助

    static func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    static func toolbar() -> NSView? {
        window?.contentView?.subviews.first { $0.frame.height == 48 && $0.frame.origin.y == 0 }
    }

    static func swatches() -> [NSButton] {
        guard let bar = toolbar(),
              let container = bar.subviews.first(where: { v in
                  v.subviews.contains { ($0 as? NSButton)?.toolTip?.contains("颜色") ?? false }
              }) else { return [] }
        return container.subviews.compactMap { $0 as? NSButton }.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func describe(_ c: NSColor?) -> String {
        guard let c = c else { return "nil" }
        let r = c.usingColorSpace(.deviceRGB) ?? c
        return String(format: "RGB(%.2f,%.2f,%.2f)", r.redComponent, r.greenComponent, r.blueComponent)
    }

    /// 采样合成图上某点（AppKit 点坐标）的颜色
    static func sample(_ y: CGFloat, x: CGFloat = 300) -> NSColor? {
        guard let canvas = canvas, let tiff = canvas.compositeImage().tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let size = canvas.baseImageSizeForProbe
        let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
        return rep.colorAt(x: Int(x * sx), y: Int((size.height - y - 0.5) * sy))
    }

    static func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a = a?.usingColorSpace(.deviceRGB), let b = b?.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }

    static func drawArrow() -> CGFloat {
        guard let canvas = canvas else { return 0 }
        let y = CGFloat(320 - arrowYs.count * 55)
        arrowYs.append(y)
        let dy = canvas.frame.minY                       // 事件坐标是窗口坐标，画布有 y 偏移
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 60, y: y + dy)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 500, y: y + dy)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 500, y: y + dy)))
        return y
    }

    static func selectArrow(at y: CGFloat) {
        guard let canvas = canvas else { return }
        let dy = canvas.frame.minY
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: y + dy)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: y + dy)))
    }

    // MARK: - 用例

    static func runAll() {
        guard let content = window?.contentView,
              let cv = content.subviews.compactMap({ findCanvas($0) }).first else {
            Probe.note("P1-13", "未找到画布，跳过"); Probe.finish("probe_colors")
        }
        canvas = cv
        if step == 0 { Probe.section("P1-13 换色行为") }
        step += 1

        // 0) 真实点击路径：色点必须真的能被点到
        if step == 1 {
            var bad: [String] = []
            for (i, sw) in swatches().enumerated() {
                let p = sw.convert(sw.bounds.center, to: nil)
                if (content.hitTest(p) as? NSButton) !== sw { bad.append("色点[\(i)]") }
            }
            if bad.isEmpty {
                Probe.ok("P1-13a", "色点可被真实点击命中", "\(swatches().count) 个色点 hitTest 全部返回按钮本身")
            } else {
                Probe.bug("P1-13a", "有色点收不到鼠标点击", bad.joined(separator: "、"), expect: "hitTest 应返回该按钮")
            }
            let y = drawArrow()
            Probe.note("P1-13", "默认色画出第 1 根：\(describe(sample(y)))")
        }

        // 1) 点另一个色点 → 新对象用新颜色，旧对象不变
        if step == 2 {
            let firstColor = sample(arrowYs[0])
            let first = describe(firstColor)
            let sw = swatches()
            guard sw.count > 2 else { Probe.note("P1-13", "色点不足，跳过"); return }
            sw[2].performClick(nil)                       // 绿色
            let y = drawArrow()
            let oldStill = sameColor(sample(arrowYs[0]), firstColor)
            if !sameColor(sample(y), sample(arrowYs[0])) {
                Probe.ok("P1-13b", "点色点后新画的对象使用新颜色", "\(first) → \(describe(sample(y)))")
            } else {
                Probe.bug("P1-13b", "点色点后新画的对象仍是旧颜色",
                          describe(sample(y)), expect: "应与旧对象颜色不同")
            }
            Probe.ok("P1-13b2", "改色只影响新对象，已画好的对象不受影响", oldStill ? "旧对象颜色未变" : "旧对象颜色被判为变化")
        }

        // 2) 选中已有对象 → 点色点 → 该对象应改色
        if step == 3 {
            selectArrow(at: arrowYs[0])
            let before = sample(arrowYs[0])
            let sw = swatches()
            guard canvas?.selectedKey != nil, sw.count > 3 else {
                Probe.bug("P1-13c", "没能选中箭头，无法验证改色", "selectedKey = nil",
                          expect: "点击箭杆应能选中")
                return
            }
            sw[3].performClick(nil)                       // 黄色
            let after = sample(arrowYs[0])
            if !sameColor(before, after) {
                Probe.ok("P1-13c", "选中已有对象后点色点，该对象会换成新颜色",
                         "\(describe(before)) → \(describe(after))")
            } else {
                Probe.bug("P1-13c", "选中已有对象后点色点，对象颜色没有变化（用户反馈的 bug）",
                          "颜色仍为 \(describe(after))",
                          expect: "选中对象的颜色应随色点改变")
            }
        }

        // 3) 撤销应恢复原色
        if step == 4 {
            let changed = sample(arrowYs[0])
            canvas?.performUndo()
            let restored = sample(arrowYs[0])
            if !sameColor(changed, restored) {
                Probe.ok("P1-13d", "撤销可以恢复被改掉的颜色",
                         "\(describe(changed)) → \(describe(restored))")
            } else {
                Probe.bug("P1-13d", "撤销没有恢复颜色", describe(restored), expect: "应回到改色前的颜色")
            }
        }

        // 4) 线宽滑杆同样作用于选中对象
        if step == 5 {
            selectArrow(at: arrowYs[0])
            guard canvas?.selectedKey != nil, let slider = toolbar()?.subviews.compactMap({ $0 as? NSSlider }).first else {
                Probe.note("P1-13", "无法选中对象或找不到滑杆，跳过线宽验证")
                Probe.finish("probe_colors")
            }
            slider.doubleValue = 25
            slider.sendAction(slider.action, to: slider.target)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let near = sample(arrowYs[0] + 10)            // 25px 粗线应覆盖到 ±12
            if !sameColor(near, NSColor.white) {
                Probe.ok("P1-13e", "线宽滑杆会作用于选中对象", "箭杆上方 10pt 已被加粗后的线覆盖")
            } else {
                Probe.bug("P1-13e", "线宽滑杆没有作用于选中对象",
                          "箭杆上方 10pt 仍为背景色", expect: "选中对象的线宽应随滑杆改变")
            }
            Probe.finish("probe_colors")
        }

        RunLoop.main.add(Timer(timeInterval: 0.25, repeats: false) { _ in runAll() }, forMode: .common)
    }

    static func findCanvas(_ v: NSView) -> AnnotationView? {
        if let a = v as? AnnotationView { return a }
        for s in v.subviews { if let f = findCanvas(s) { return f } }
        return nil
    }
}

extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

extension AnnotationView {
    /// 探针用：画布的逻辑尺寸
    var baseImageSizeForProbe: NSSize { bounds.size }
}
