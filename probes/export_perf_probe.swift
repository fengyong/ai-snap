// 导出路径的成本拆解探针（P2-8 量化的前置）。
//
// 动机：⌘C / ⌘S 的「合成 → 编码 → 写盘」全在主线程，大图冻 UI 数百毫秒。
// 修之前先量清楚每一段占多少 —— 只把真正占大头的那几段挪后台，不为小头冒险。
//
// 被测的四段（全部可离屏复现）：
//   1. compositeImage()      —— 显式位图分配 + 底图/对象/水印全分辨率重绘
//   2. ImageEncode.png       —— PNG 编码（deflate，预期大头）
//   3. data.write(to:)       —— 写盘
//   4. tiffRepresentation    —— writeObjects([NSImage]) 内部成本的代表
//                               （AppKit 给剪贴板写 NSImage 时会即时编码 TIFF；
//                                探针不能碰真实剪贴板，用它做代理）
//
// 场景：2x 倍率的 1600×1000（=3200×2000 像素）合成截图 + 30 个混合标注对象
// —— 与「Retina 全屏标注一堆箭头」的日常 worst case 同量级。
//
//      run_probe export_perf_probe   "${ALL_SOURCES[@]}"
import Cocoa
import ImageIO

setbuf(stdout, nil)

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s[s.count / 2]
}

// ── 场景搭建：2x Retina 全屏 + 30 个混合对象 ──
//
// 底图内容必须**像真实截图**：编码成本对内容极其敏感 —— 纯色块 deflate 几乎
// 白送（首版探针 3200×2000 只编出 0.2MB / 28.8ms，严重低估），文字的抗锯齿边
// 与随机噪声才是真实的压缩负担。这里铺满文字行 + 一块随机噪声区。
let pixelW = 3200, pixelH = 2000
let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                    bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
// ① 文字行（模拟 IDE / 网页正文）：抗锯齿边缘压缩开销大
do {
    let line = "func handleTap(_ gesture: UITapGestureRecognizer) { viewModel.select(at: gesture.location(in: view).y) } // 0x7f8a1b"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
        .foregroundColor: NSColor.black,
    ]
    let nsLine = line as NSString
    for row in 0..<70 {
        nsLine.draw(at: NSPoint(x: 24, y: CGFloat(row) * 28 + 8), withAttributes: attrs)
    }
}
// ② 随机噪声区（模拟照片 / 视频帧）：deflate 的最坏情况
var seed: UInt64 = 0x9E3779B97F4A7C15
for y in 0..<600 {
    for x in 0..<800 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let r = UInt8(truncatingIfNeeded: seed >> 33)
        let g = UInt8(truncatingIfNeeded: seed >> 21)
        let b = UInt8(truncatingIfNeeded: seed >> 9)
        ctx.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                 blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(2200 + x), y: CGFloat(400 + y), width: 1, height: 1))
    }
}
let baseCG = ctx.makeImage()!
let baseImage = NSImage(cgImage: baseCG, size: NSSize(width: 1600, height: 1000))

let view = AnnotationView(image: baseImage, pixelSize: CGSize(width: pixelW, height: pixelH))
view.currentTool = .arrow
view.currentLineWidth = 3

func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0,
                       clickCount: 1, pressure: 1)!
}
// 10 根箭头 + 10 个矩形 + 5 段画笔 + 5 个序号。
// 布局注意：默认线宽 15 → 命中带 ±10.5pt，前一个矩形的边带会吞掉贴太近的
// 下一个起点（把它变成移动而不是新画）—— 矩形按 x+150/y+20 错开。
for i in 0..<10 {
    view.currentTool = .arrow
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100 + CGFloat(i) * 60, y: 800)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300 + CGFloat(i) * 60, y: 950)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300 + CGFloat(i) * 60, y: 950)))
    view.currentTool = .rectangle
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100 + CGFloat(i) * 150, y: 300 + CGFloat(i) * 20)))
    view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 260 + CGFloat(i) * 150, y: 420 + CGFloat(i) * 20)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 260 + CGFloat(i) * 150, y: 420 + CGFloat(i) * 20)))
}
view.currentTool = .pen
for i in 0..<5 {
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200 + CGFloat(i) * 200, y: 600)))
    for j in 1...8 {
        view.mouseDragged(with: mouse(.leftMouseDragged,
                                      CGPoint(x: 200 + CGFloat(i) * 200 + CGFloat(j) * 30,
                                              y: 600 + CGFloat(j % 3) * 20)))
    }
    view.mouseUp(with: mouse(.leftMouseUp,
                             CGPoint(x: 200 + CGFloat(i) * 200 + 240, y: 620)))
}
view.currentTool = .step
for i in 0..<5 {
    view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 1500, y: 100 + CGFloat(i) * 60)))
    view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 1500, y: 100 + CGFloat(i) * 60)))
}
print("场景：\(view.objects.count) 个标注对象（底图 = 70 行文字 + 800×600 噪声区）")

// ── 测量 ──
func timeIt(_ rounds: Int, _ label: String, _ block: () -> Void) {
    // 预热一轮（首次解码/缓存分配不代表稳态）
    block()
    var samples: [Double] = []
    for _ in 0..<rounds {
        let t0 = DispatchTime.now()
        block()
        let t1 = DispatchTime.now()
        samples.append(Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
    }
    print("  \(label)：中位 \(String(format: "%.1f", median(samples))) ms" +
          "（\(rounds) 轮：\(samples.map { String(format: "%.0f", $0) }.joined(separator: "/"))）")
}

let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("aisnap-perf-probe-\(UUID().uuidString.prefix(6)).png")
defer { try? FileManager.default.removeItem(at: url) }

var composite: NSImage?
timeIt(5, "① compositeImage（合成）      ") { composite = view.compositeImage() }
var pngData: Data?
timeIt(5, "② ImageEncode.png（PNG 编码）") { pngData = ImageEncode.png(from: composite!) }
timeIt(5, "③ data.write（写盘）          ") { try! pngData!.write(to: url) }
timeIt(5, "④ tiffRepresentation（剪贴板代理）") { _ = composite!.tiffRepresentation }

let pngMB = Double(pngData!.count) / 1_048_576
print("\n  场景像素 \(pixelW)×\(pixelH)，PNG \(String(format: "%.1f", pngMB)) MB")
print("  结论基准：①+④ 留主线程的下限；②+③ 是可挪后台的部分")
