import Cocoa

//  探针 06 — Layer B 调试面板带来的拖拽开销（报告 P1-5）
//
//  对照实验：同一个画布、同样的拖拽序列，唯一差别是 debugImageView 是否挂载。
//  （AnnotationWindow 默认一定挂载，所以"开"这一列就是 App 的真实状态。）

@main
struct PerfProbe {
    static func main() {
        bootstrapApp()
        Probe.section("P1-5 每次 mouseDragged 的耗时（2560×1440 画布，20 个对象）")

        let canvasSize = CGSize(width: 2560, height: 1440)
        var keepAlive: [NSImageView] = []

        func build(debugOn: Bool) -> AnnotationView {
            let view = AnnotationView(image: blankCanvas(canvasSize.width, canvasSize.height))
            view.currentLineWidth = 15
            view.currentTool = .rectangle
            for i in 0..<20 {
                let x = CGFloat(40 + (i % 5) * 200)
                let y = CGFloat(40 + (i / 5) * 150)
                drag(view, from: CGPoint(x: x, y: y), to: CGPoint(x: x + 150, y: y + 100))
            }
            if debugOn {
                let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
                keepAlive.append(iv)              // debugImageView 是 weak，必须外部持有
                view.debugImageView = iv
            }
            return view
        }

        func measure(debugOn: Bool) -> Double {
            let view = build(debugOn: debugOn)
            func oneDrag(_ i: Int) {              // 拖动第 0 个矩形的下边缘 → 走 .moving 分支
                let y: CGFloat = 40
                view.mouseDown(with: mouseEvent(.leftMouseDown, CGPoint(x: 115, y: y)))
                view.mouseDragged(with: mouseEvent(.leftMouseDragged, CGPoint(x: 115 + CGFloat(i), y: y)))
                view.mouseUp(with: mouseEvent(.leftMouseUp, CGPoint(x: 115 + CGFloat(i), y: y)))
            }
            for i in 0..<5 { oneDrag(i) }          // 预热
            let n = 40
            let t0 = CFAbsoluteTimeGetCurrent()
            for i in 0..<n { oneDrag(i) }
            return (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
        }

        let off = measure(debugOn: false)
        let on = measure(debugOn: true)
        Probe.note("P1-5", String(format: "调试面板关：%.2f ms/事件（%.0f 次/秒上限）；开：%.2f ms/事件（%.0f 次/秒上限）；放大 %.0f 倍",
                                  off, 1000 / off, on, 1000 / on, on / off))

        // 应用默认是"关闭"：这一条必须快。
        if off <= 8.0 {
            Probe.ok("P1-5", "默认（调试面板关闭）拖拽开销可接受",
                     String(format: "%.2f ms/事件 → 上限约 %.0f 次/秒", off, 1000 / off))
        } else {
            Probe.bug("P1-5", "默认状态下拖拽开销仍然过高",
                      String(format: "%.2f ms/事件", off), expect: "应 < 8ms/事件")
        }
        // 显式打开调试面板后的开销只作记录：它是可选的调试功能，代价已知即可。
        Probe.note("P1-5b", String(format: "显式打开调试面板时约 %.1f ms/事件（该功能现在默认关闭、可从「视图」菜单开关）", on))

        // 对照：整张画布的 draw() 成本（说明瓶颈不是渲染本身，而是调试可视化）
        let view = build(debugOn: false)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(canvasSize.width), pixelsHigh: Int(canvasSize.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            Probe.finish("probe_perf")
        }
        func frame() {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        frame()
        let n = 20
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { frame() }
        let drawMs = (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
        Probe.note("P1-5b", String(format: "对照：整张画布 draw() 仅 %.2f ms/帧（包含底图 + 20 个对象）", drawMs))

        Probe.finish("probe_perf")
    }
}
