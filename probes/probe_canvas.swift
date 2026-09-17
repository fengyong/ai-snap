import Cocoa

//  探针 04 — 画布行为：命中检测 / 撤销重做（回归基线）+ P1-6 / P1-7

@main
struct CanvasProbe {
    static func main() {
        bootstrapApp()

        // ── 命中检测（报告 §7 的正向基线，改动后应始终通过）──
        Probe.section("命中检测基线（双图层 Color Picking）")
        let v = newCanvas()
        v.currentTool = .rectangle
        drag(v, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 120))
        func expect(_ id: String, _ claim: String, _ got: Bool, _ want: Bool, at p: CGPoint) {
            if got == want { Probe.ok(id, claim, "点 \(p) 选中=\(got)") }
            else { Probe.bug(id, claim, "点 \(p) 选中=\(got)", expect: "应为 \(want)") }
        }
        expect("HIT-1", "矩形描边可选中", selects(v, at: CGPoint(x: 100, y: 50)), true, at: CGPoint(x: 100, y: 50))
        expect("HIT-2", "矩形内部空白不误选", selects(v, at: CGPoint(x: 100, y: 85)), false, at: CGPoint(x: 100, y: 85))
        v.currentTool = .arrow
        drag(v, from: CGPoint(x: 200, y: 40), to: CGPoint(x: 320, y: 40))
        expect("HIT-3", "箭头杆可选中", selects(v, at: CGPoint(x: 260, y: 40)), true, at: CGPoint(x: 260, y: 40))
        v.currentTool = .ellipse
        drag(v, from: CGPoint(x: 200, y: 60), to: CGPoint(x: 300, y: 160))
        expect("HIT-4", "椭圆轮廓可选中", selects(v, at: CGPoint(x: 300, y: 110)), true, at: CGPoint(x: 300, y: 110))
        expect("HIT-5", "椭圆内部不误选", selects(v, at: CGPoint(x: 250, y: 110)), false, at: CGPoint(x: 250, y: 110))
        v.currentTool = .stamp(.emoji("\u{1F44D}"))
        click(v, at: CGPoint(x: 380, y: 250))
        expect("HIT-6", "贴纸单击放置并可再次选中", selects(v, at: CGPoint(x: 380, y: 250)), true, at: CGPoint(x: 380, y: 250))

        // ── 撤销/重做像素级回归 ──
        Probe.section("撤销/重做：9 步混合操作全撤销再全重做，合成图哈希应逐步一致")
        let u = newCanvas()
        var states: [UInt64] = [imageHash(u.compositeImage())]
        func snap() { states.append(imageHash(u.compositeImage())) }
        u.currentTool = .rectangle
        drag(u, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 140, y: 120));  snap()
        u.currentTool = .arrow
        drag(u, from: CGPoint(x: 350, y: 280), to: CGPoint(x: 85, y: 75));  snap()   // 附着到矩形中心
        _ = selects(u, at: CGPoint(x: 85, y: 30))
        drag(u, from: CGPoint(x: 85, y: 30), to: CGPoint(x: 85, y: 60));    snap()   // 移动
        _ = selects(u, at: CGPoint(x: 85, y: 30))
        drag(u, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 230, y: 130), .option); snap()  // 旋转
        _ = selects(u, at: CGPoint(x: 85, y: 60))
        drag(u, from: CGPoint(x: 250, y: 150), to: CGPoint(x: 300, y: 200), .shift);  snap()  // 缩放
        u.currentTool = .stamp(.emoji("\u{1F525}"))
        click(u, at: CGPoint(x: 300, y: 60));  snap()                                // 放置贴纸
        _ = selects(u, at: CGPoint(x: 300, y: 60)); pressDelete(u);  snap()           // 删除贴纸
        u.currentTool = .ellipse
        drag(u, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 330, y: 280)); snap()  // 画椭圆
        _ = selects(u, at: CGPoint(x: 200, y: 240)); pressDelete(u);  snap()          // 删除椭圆

        var undoOK = true
        for i in 1..<states.count {
            u.performUndo()
            if imageHash(u.compositeImage()) != states[states.count - 1 - i] { undoOK = false }
        }
        var redoOK = true
        for i in 0..<(states.count - 1) {
            u.performRedo()
            if imageHash(u.compositeImage()) != states[i + 1] { redoOK = false }
        }
        if undoOK { Probe.ok("UNDO-1", "全部撤销后逐步回到历史状态", "\(states.count - 1) 步全部一致") }
        else { Probe.bug("UNDO-1", "撤销过程中状态与历史不一致", "存在哈希不匹配的步骤", expect: "每一步都应完全一致") }
        if redoOK { Probe.ok("UNDO-2", "全部重做后逐步回到历史状态", "\(states.count - 1) 步全部一致") }
        else { Probe.bug("UNDO-2", "重做过程中状态与历史不一致", "存在哈希不匹配的步骤", expect: "每一步都应完全一致") }

        // ── P1-6: 选中对象后，空白处的 Option / Shift 拖拽仍会改动它 ──
        Probe.section("P1-6 空白处（远离选中对象）的 Option / Shift 拖拽")
        let w = newCanvas()
        w.currentTool = .rectangle
        drag(w, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        _ = selects(w, at: CGPoint(x: 100, y: 50))
        if w.selectedKey == nil {
            Probe.note("P1-6", "未能选中矩形，探针前置条件不满足，跳过")
        } else {
            let before = imageHash(w.compositeImage())
            // 空白处 Option 拖拽：正确行为是"照常画一个新矩形"，
            // 而不是把远处那个已选对象旋转掉（旧实现不检查按下位置）。
            drag(w, from: CGPoint(x: 400, y: 330), to: CGPoint(x: 470, y: 390), .option)
            let drewNew = selects(w, at: CGPoint(x: 435, y: 330))   // 新矩形下边缘中部
            w.performUndo()                                          // 撤掉这次新画的矩形
            let afterUndo = imageHash(w.compositeImage())
            if drewNew {
                Probe.ok("P1-6a", "空白处 Option 拖拽照常绘制新图形（不再劫持为旋转）",
                         "新矩形可选中；撤销后回到原状 = \(before == afterUndo)")
            } else {
                Probe.bug("P1-6a", "空白处 Option 拖拽没有绘制新图形（被劫持成旋转已选中对象）",
                          "拖拽位置没有出现新对象（撤销后状态一致 = \(before == afterUndo)）",
                          expect: "应画出新矩形；旋转/缩放只应在按住对象时触发")
            }
            // Shift 拖拽空白处应画新矩形，而不是缩放选中的那个
            w.currentTool = .rectangle
            drag(w, from: CGPoint(x: 250, y: 250), to: CGPoint(x: 350, y: 330), .shift)
            let drew = selects(w, at: CGPoint(x: 300, y: 250))
            if drew {
                Probe.ok("P1-6b", "空白处 Shift 拖拽正常绘制新矩形", "新矩形可选中")
            } else {
                Probe.bug("P1-6b", "空白处 Shift 拖拽没有绘制新图形（被劫持为缩放选中对象）",
                          "点 (300,250) 选中=false", expect: "应画出新矩形并可选中")
            }
        }

        // ── P1-7: 移动箭头会解除附着，撤销无法恢复 ──
        Probe.section("P1-7 轻微拖动箭头解除附着后，撤销是否恢复附着")
        let a = newCanvas()
        a.currentTool = .rectangle
        drag(a, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        a.currentTool = .arrow
        drag(a, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100))   // 附着到矩形中心
        let arrowPicked = selects(a, at: CGPoint(x: 200, y: 175))
        if !arrowPicked {
            Probe.note("P1-7", "未能选中箭头，探针前置条件不满足，跳过")
        } else {
            drag(a, from: CGPoint(x: 200, y: 175), to: CGPoint(x: 205, y: 175))   // 轻推 → 解除附着
            a.performUndo()                                                        // 撤销这次移动
            _ = selects(a, at: CGPoint(x: 100, y: 50))                             // 选中矩形
            drag(a, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 100, y: 90))      // 移动矩形
            // 若附着仍在，箭头端点应跟随到矩形中心新位置；否则留在原处
            let followed = selects(a, at: CGPoint(x: 200, y: 205))                 // (300,250)->(100,140) 的中点
            if followed {
                Probe.ok("P1-7", "撤销移动后附着关系仍在", "箭头端点跟随了矩形")
            } else {
                Probe.bug("P1-7", "撤销移动后附着关系永久丢失（解除附着不可撤销）",
                          "移动矩形后箭头端点未跟随",
                          expect: "撤销应恢复附着，箭头端点应跟随矩形中心")
            }
        }

        Probe.finish("probe_canvas")
    }
}
