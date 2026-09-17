import Cocoa

//  探针 02 — 标注窗口布局（报告 P0-2 + P4-19 色板切换重排）
//
//  用真实 AnnotationWindow 实例测量：不同尺寸截图下窗口有多宽、
//  工具栏实际需要多宽、导出按钮是否落在窗口内、是否还能用键盘够到。

@main
struct LayoutProbe {
    static var window: AnnotationWindow?

    static func main() {
        bootstrapApp(policy: .regular)
        NSApp.activate(ignoringOtherApps: true)
        let img = blankCanvas(200, 150)                  // 小截图 → 窗口被钳到最小宽度
        let w = AnnotationWindow(image: img)
        window = w
        w.makeKeyAndOrderFront(nil)
        let t = Timer(timeInterval: 0.4, repeats: false) { _ in inspect() }
        RunLoop.main.add(t, forMode: .common)
        NSApp.run()
    }

    static func inspect() {
        guard let w = window, let content = w.contentView else {
            Probe.note("P0-2", "未找到窗口，跳过"); Probe.finish("probe_layout")
        }
        guard let bar = content.subviews.first(where: { $0.frame.height == 48 && $0.frame.origin.y == 0 }) else {
            Probe.note("P0-2", "未找到工具栏视图，跳过"); Probe.finish("probe_layout")
        }

        Probe.section("P0-2 工具栏所需宽度 vs 窗口实际宽度（源图 200×150）")
        let needed = bar.subviews.map { $0.frame.maxX }.max() ?? 0
        let have = bar.frame.width
        Probe.note("P0-2", String(format: "窗口宽 %.0f pt，工具栏内容需要 %.0f pt，溢出 %.0f pt", have, needed, needed - have))

        let buttons = bar.subviews.compactMap { $0 as? NSButton }
        var clipped: [String] = []
        for title in ["保存", "复制", "帮助"] {
            guard let b = buttons.first(where: { $0.title == title }) else { continue }
            let inside = b.frame.maxX <= have
            Probe.note("P0-2", String(format: "  「%@」frame = x %.0f...%.0f，在窗口内 = %@", title, b.frame.minX, b.frame.maxX, inside ? "是" : "否"))
            if !inside { clipped.append(title) }
        }
        if clipped.isEmpty {
            Probe.ok("P0-2", "导出按钮都在窗口内", "无按钮被裁切")
        } else {
            Probe.bug("P0-2", "导出按钮被排在窗口之外（鼠标点不到、也看不见）",
                      "被裁切：\(clipped.joined(separator: "、"))",
                      expect: "窗口最小宽度应按工具栏实际所需宽度计算，或工具栏可折行/可滚动")
        }

        // 键盘可达性：按钮虽在窗口外，但仍可能留在 key view loop 里
        Probe.section("P0-2 键盘可达性与系统「全键盘控制」设置")
        let full = UserDefaults.standard.object(forKey: "AppleKeyboardUIMode") as? Int
        Probe.note("P0-2", "AppleKeyboardUIMode = \(full.map(String.init) ?? "未设置（=0，Tab 只在文本框间移动）")")
        var cur: NSView? = w.firstResponder as? NSView
        var reached = false
        for _ in 0..<80 {
            guard let c = cur else { break }
            if (c as? NSButton)?.title == "保存" { reached = true; break }
            guard let next = c.nextKeyView, (next as AnyObject?) !== c else { break }
            cur = next
        }
        Probe.note("P0-2", "「保存」是否在 key view loop 中：\(reached ? "是" : "否")（需系统开启全键盘控制才能用 Tab 够到，且不可见无反馈）")
        let hasSaveMenu = (NSApp.mainMenu?.items ?? []).contains { item in
            (item.submenu?.items ?? []).contains { ($0.action.map(NSStringFromSelector) ?? "").lowercased().contains("save") }
        }
        if hasSaveMenu {
            Probe.ok("P0-2c", "应用菜单里有保存项作为兜底入口（Cmd+S）", "存在")
        } else {
            Probe.bug("P0-2c", "没有 Cmd+S / 菜单保存项兜底",
                      "主菜单中不存在任何 save 动作",
                      expect: "应提供与布局无关的导出入口（Cmd+S / 编辑菜单）")
        }

        // ── P1-5: Layer B 调试面板默认必须关闭 ──
        Probe.section("P1-5 调试面板默认状态")
        func findCanvas(_ v: NSView) -> AnnotationView? {
            if let a = v as? AnnotationView { return a }
            for sub in v.subviews { if let f = findCanvas(sub) { return f } }
            return nil
        }
        if let canvas = findCanvas(content) {
            let attached = canvas.debugImageView != nil
            let hasDebugImage = content.subviews.contains { $0 is NSImageView && $0.isHidden == false }
            if !attached && !hasDebugImage {
                Probe.ok("P1-5", "调试面板默认关闭（拖拽不再重绘 Layer B 可视化）", "debugImageView = nil")
            } else {
                Probe.bug("P1-5", "调试面板仍然默认挂载",
                          "debugImageView 已挂载 = \(attached)，存在可见 NSImageView = \(hasDebugImage)",
                          expect: "默认应为关闭，通过「视图 → 显示 Layer B 调试面板」按需打开")
            }
        } else {
            Probe.note("P1-5", "未找到画布，跳过")
        }

        // ── P4-19: 切换调色板时只重建色板，不重排后续控件 ──
        Probe.section("P4-19 切换调色板（4 色 → 5 色）后工具栏是否重排")
        guard let container = bar.subviews.first(where: { v in
            v.subviews.contains { ($0 as? NSButton)?.toolTip?.contains("颜色") ?? false }
        }) else {
            Probe.note("P4-19", "未找到色板容器，跳过"); Probe.finish("probe_layout")
        }
        let slider = bar.subviews.compactMap { $0 as? NSSlider }.first
        func swatchRight() -> CGFloat {
            let dots = container.subviews.compactMap { $0 as? NSButton }
            return container.frame.minX + (dots.map { $0.frame.maxX }.max() ?? 0)
        }
        let before = swatchRight()
        buttons.first { $0.title == "换色" }?.performClick(nil)
        let after = swatchRight()
        guard let s = slider else { Probe.note("P4-19", "未找到线宽滑杆，跳过"); Probe.finish("probe_layout") }
        Probe.note("P4-19", String(format: "4 色时色板右边界 %.0f，切换后 %.0f，后续控件起点 %.0f", before, after, s.frame.minX))
        if after <= s.frame.minX {
            Probe.ok("P4-19", "切换调色板后没有与后续控件重叠", String(format: "%.0f ≤ %.0f", after, s.frame.minX))
        } else {
            Probe.bug("P4-19", "切换到 5 色板后色板压住后面的分隔线/线宽标签（cyclePalette 只重建色板，不重排工具栏）",
                      String(format: "色板右边界 %.0f > 后续控件起点 %.0f，重叠 %.0f pt", after, s.frame.minX, after - s.frame.minX),
                      expect: "切换色板后应重新计算后续控件位置")
        }

        Probe.finish("probe_layout")
    }
}
