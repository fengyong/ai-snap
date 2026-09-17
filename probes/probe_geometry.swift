import Cocoa

//  探针 03 — 几何与附着（报告 P1-8 / P1-9 / P4 第 13、14 条）
//
//  编译：见 run_all.sh（需要 Models.swift / HitTestBuffer.swift / AnnotationView.swift）
//  这些结论与会话状态无关，任何机器上都应复现。

@main
struct GeometryProbe {
    static func main() {
        bootstrapApp()

        // ── P1-8a: CircleShape.nearestPerimeterPoint 的数学正确性 ──
        Probe.section("P1-8 椭圆 neareastPerimeterPoint —— 输入点就在椭圆上时误差应为 0")
        let ellipse = CircleShape(center: CGPoint(x: 200, y: 150),
                                  radiusX: 100, radiusY: 50,
                                  color: .red, lineWidth: 3, hitTestColorKey: 1)
        var worst: CGFloat = 0
        var samples: [String] = []
        for deg in stride(from: 0.0, through: 90.0, by: 15.0) {
            let a = deg * .pi / 180
            let onCurve = CGPoint(x: 200 + 100 * cos(a), y: 150 + 50 * sin(a))
            let got = ellipse.nearestPerimeterPoint(to: onCurve)
            let err = hypot(got.x - onCurve.x, got.y - onCurve.y)
            worst = max(worst, err)
            samples.append(String(format: "θ=%.0f° err=%.0f", deg, err))
        }
        if worst < 0.01 {
            Probe.ok("P1-8a", "nearestPerimeterPoint 返回椭圆上的点", "最大误差 \(String(format: "%.3f", worst)) px")
        } else {
            Probe.bug("P1-8a", "nearestPerimeterPoint 返回的点不在椭圆上（多乘了一次半径）",
                      samples.joined(separator: "  "),
                      expect: "所有输入点在椭圆上时误差应为 0")
        }

        // ── P1-8b: 端到端 —— 箭头端点落在椭圆轮廓上能否附着 ──
        Probe.section("P1-8b 端到端：端点精确落在椭圆轮廓上，移动椭圆后箭头是否跟随")
        let v1 = newCanvas()
        v1.currentTool = .ellipse
        drag(v1, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))   // 中心(200,150) rx=100 ry=50
        let tip = CGPoint(x: 200 + 100 * cos(Double.pi / 4), y: 150 + 50 * sin(Double.pi / 4))
        v1.currentTool = .arrow
        drag(v1, from: CGPoint(x: 420, y: 360), to: tip)
        _ = selects(v1, at: CGPoint(x: 100, y: 150))                            // 选中椭圆（左象限点）
        let ellipseSelected = v1.selectedKey != nil
        drag(v1, from: CGPoint(x: 100, y: 150), to: CGPoint(x: 100, y: 90))     // 椭圆下移 60
        // 若跟随，箭头端点会移到椭圆新轮廓上；旧端点应变成空白
        let stillThere = selects(v1, at: tip)
        if !ellipseSelected {
            Probe.note("P1-8b", "未能选中椭圆，探针前置条件不满足，跳过")
        } else if stillThere {
            Probe.bug("P1-8b", "箭头端点未能附着到椭圆轮廓（旧端点仍被占据 = 箭头留在原地）",
                      "拖动椭圆后 \(tip) 仍可选中对象",
                      expect: "端点应附着并跟随，旧端点应为空白")
        } else {
            Probe.ok("P1-8b", "箭头端点成功附着到椭圆并跟随", "旧端点已变为空白")
        }

        // ── P1-9: 旋转 / 缩放父形状时附着箭头是否跟随 ──
        //  注意：P1-6 修复后，Option/Shift 拖拽必须**从对象上开始**才会进入旋转/缩放；
        //  另外箭头的起点要选在"新附着点的正下方"，这样旧附着点不会落在新箭杆的命中范围内，
        //  否则探针分不清"箭头跟过去了"还是"箭头留在原地"。
        Probe.section("P1-9 旋转/缩放父形状时，附着箭头是否跟随（MOVE 为对照组）")
        func attachmentFollows(start: CGPoint,
                               gesture: (AnnotationView) -> Void) -> Bool {
            let v = newCanvas()
            v.currentTool = .rectangle
            drag(v, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160))   // 角点 (100,100)
            v.currentTool = .arrow
            drag(v, from: start, to: CGPoint(x: 100, y: 100))                     // 端点在角点上
            _ = selects(v, at: CGPoint(x: 150, y: 100))                           // 选中矩形
            guard v.selectedKey != nil else { return false }
            gesture(v)
            // 变换后父对象轮廓都已离开 (100,100)；该点若仍被占据 ⇒ 箭头留在原地
            return !selects(v, at: CGPoint(x: 100, y: 100))
        }

        // 对照组：移动 (+130,-60) → 新附着点 (230,40)，起点取其正下方
        let moved = attachmentFollows(start: CGPoint(x: 230, y: 380)) { v in
            v.mouseDown(with: mouseEvent(.leftMouseDown, CGPoint(x: 150, y: 100)))
            v.mouseDragged(with: mouseEvent(.leftMouseDragged, CGPoint(x: 280, y: 40)))
            v.mouseUp(with: mouseEvent(.leftMouseUp, CGPoint(x: 280, y: 40)))
        }
        // 旋转 +90°（从底边中点按下，绕过中心）→ 新附着点 (180,80)
        let rotated = attachmentFollows(start: CGPoint(x: 180, y: 380)) { v in
            v.mouseDown(with: mouseEvent(.leftMouseDown, CGPoint(x: 150, y: 100), .option))
            v.mouseDragged(with: mouseEvent(.leftMouseDragged, CGPoint(x: 330, y: 130), .option))
            v.mouseUp(with: mouseEvent(.leftMouseUp, CGPoint(x: 330, y: 130), .option))
        }
        // 缩放 ×2（距离 30 → 60）→ 新附着点 (50,70)
        let scaled = attachmentFollows(start: CGPoint(x: 50, y: 380)) { v in
            v.mouseDown(with: mouseEvent(.leftMouseDown, CGPoint(x: 150, y: 100), .shift))
            v.mouseDragged(with: mouseEvent(.leftMouseDragged, CGPoint(x: 150, y: 70), .shift))
            v.mouseUp(with: mouseEvent(.leftMouseUp, CGPoint(x: 150, y: 70), .shift))
        }

        if moved {
            Probe.ok("P1-9a", "移动父对象时箭头跟随（对照组）", "旧附着点已空")
        } else {
            Probe.bug("P1-9a", "对照组失败：连移动都不跟随，探针本身可能有问题",
                      "旧附着点仍被占据", expect: "应变为空")
        }
        if rotated {
            Probe.ok("P1-9b", "旋转父对象时箭头跟随", "旋转 +90° 后旧附着点已空")
        } else {
            Probe.bug("P1-9b", "旋转父对象时附着箭头不跟随",
                      "旧附着点 (100,100) 仍被箭头占据",
                      expect: "端点应跟随到旋转后的角点 (180,80)")
        }
        if scaled {
            Probe.ok("P1-9c", "缩放父对象时箭头跟随", "缩放 ×2 后旧附着点已空")
        } else {
            Probe.bug("P1-9c", "缩放父对象时附着箭头不跟随",
                      "旧附着点 (100,100) 仍被箭头占据",
                      expect: "端点应跟随到缩放后的角点 (50,70)")
        }

        // ── P4-13: pointOnPerimeter 是否真的落在周长上（公开 API 的几何自检）──
        Probe.section("P4-13 pointOnPerimeter 采样点是否落在图形周长上")
        let rect = RectangleShape(center: CGPoint(x: 300, y: 300), width: 200, height: 100,
                                  color: .red, lineWidth: 2, hitTestColorKey: 2)
        rect.rotation = 0.5
        let circle = CircleShape(center: CGPoint(x: 300, y: 300), radiusX: 80, radiusY: 40,
                                 color: .red, lineWidth: 2, hitTestColorKey: 3)
        circle.rotation = -1.2
        let stamp = StampObject(center: CGPoint(x: 300, y: 300), size: 60, stampType: .checkmark,
                                color: .red, hitTestColorKey: 4)
        stamp.rotation = 0.3
        func maxRectResidual(_ r: RectangleShape) -> CGFloat {
            var worst: CGFloat = 0
            for i in 0...200 {
                let p = r.pointOnPerimeter(at: CGFloat(i) / 200)
                let local = rotatePoint(p, around: r.center, by: -r.rotation)
                let dx = abs(local.x - r.center.x) - r.width / 2
                let dy = abs(local.y - r.center.y) - r.height / 2
                worst = max(worst, min(abs(dx), abs(dy)))       // 到最近一条边的距离
            }
            return worst
        }
        func maxEllipseResidual(_ c: CircleShape) -> CGFloat {
            var worst: CGFloat = 0
            for i in 0...200 {
                let p = c.pointOnPerimeter(at: CGFloat(i) / 200)
                let local = rotatePoint(p, around: c.center, by: -c.rotation)
                let x = (local.x - c.center.x) / c.radiusX
                let y = (local.y - c.center.y) / c.radiusY
                worst = max(worst, abs(hypot(x, y) - 1) * min(c.radiusX, c.radiusY))
            }
            return worst
        }
        let rectErr = maxRectResidual(rect), circleErr = maxEllipseResidual(circle)
        if rectErr < 0.01 && circleErr < 0.01 {
            Probe.ok("P4-13", "pointOnPerimeter 采样点落在周长上",
                     String(format: "矩形最大偏差 %.4f px，椭圆最大偏差 %.4f px", rectErr, circleErr))
        } else {
            Probe.bug("P4-13", "pointOnPerimeter 采样点偏离周长",
                      String(format: "矩形 %.4f px，椭圆 %.4f px", rectErr, circleErr),
                      expect: "两者都应 < 0.01 px")
        }

        // ── P4-14: 附着阈值(15) > 吸附预览阈值(12) ⇒ 松手瞬间端点跳动 ──
        Probe.section("P4-14 吸附阈值 12pt 与附着阈值 15pt 不一致导致的松手跳变")
        let v2 = newCanvas()
        v2.currentTool = .rectangle
        drag(v2, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))   // 上边 y=200，边中点 (200,200)
        v2.currentTool = .arrow
        let release = CGPoint(x: 200, y: 214)                                   // 距上边 14pt：>12 不吸附，<15 会附着
        drag(v2, from: CGPoint(x: 60, y: 260), to: release)
        if selects(v2, at: release) {
            Probe.ok("P4-14", "松手点处仍有箭头端点（无跳变）", "释放点 \(release) 可选中")
        } else {
            Probe.bug("P4-14", "松手后端点被吸附走，与拖拽预览不一致（阈值 12 vs 15）",
                      "释放点 \(release)（距轮廓 14pt）已无箭头",
                      expect: "端点应停在释放点，或预览阶段就吸附（两阈值一致）")
        }

        Probe.finish("probe_geometry")
    }
}
