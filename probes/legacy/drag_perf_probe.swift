// 拖拽重绘成本基准探针
//
// 目的：判定「拖拽时全量重绘」是否真的可以按「对象少所以无所谓」关闭。
//
// redrawAll 的成本 = clear()（整画布 fill，O(W×H)，与对象数无关）
//                  + N × drawObject（O(N)）
// 本探针把这两项分开计时，看固定成本项到底有多大。
//
// 说明：这里复刻的是成本结构（同样的 CGContext 尺寸、同样的 clear + 描线/填充），
// 不是 App 本体（executable target 无法 import）。绝对数值可能略有出入，
// 但量级和「与对象数无关」这个结论是可靠的。

import Cocoa

// ── 复刻 HitTestBuffer 的缓冲区与绘制路径 ──

final class ProbeBuffer {
    let context: CGContext
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let cs = CGColorSpaceCreateDeviceRGB()
        context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        clear()
    }

    func clear() {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// 复刻一次 drawHitTest 的代价：描一条线 + 填一个圆
    func drawMockObject(index: Int) {
        let c = NSColor(red: CGFloat((index * 37) % 255) / 255.0,
                        green: CGFloat((index * 91) % 255) / 255.0,
                        blue: CGFloat((index * 53) % 255) / 255.0, alpha: 1.0)
        context.setStrokeColor(c.cgColor)
        context.setLineWidth(21)          // lineWidth 15 + 6 slop
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 40, y: 40))
        context.addLine(to: CGPoint(x: CGFloat(width) - 40, y: CGFloat(height) - 40))
        context.strokePath()
        context.setFillColor(c.cgColor)
        context.fillEllipse(in: CGRect(x: 100, y: 100, width: 60, height: 60))
    }

    func redrawAll(objectCount: Int) {
        clear()
        for i in 0..<objectCount { drawMockObject(index: i) }
    }

    /// 复刻 debugVisualization：另一个整画布渲染
    func debugVisualization(objectCount: Int) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        for i in 0..<objectCount {
            let hue = (CGFloat(i + 1) * 0.618033988749895).truncatingRemainder(dividingBy: 1.0)
            let c = NSColor(hue: hue, saturation: 0.85, brightness: 0.95, alpha: 1.0)
            ctx.setStrokeColor(c.cgColor)
            ctx.setLineWidth(21)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 40, y: 40))
            ctx.addLine(to: CGPoint(x: CGFloat(width) - 40, y: CGFloat(height) - 40))
            ctx.strokePath()
        }
        return image
    }
}

func bench(_ label: String, iterations: Int = 100, _ body: () -> Void) -> Double {
    // 预热
    for _ in 0..<5 { body() }
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations { body() }
    let dt = (CFAbsoluteTimeGetCurrent() - t0) / Double(iterations) * 1000.0
    print(String(format: "  %-46@ %7.2f ms", label as NSString, dt))
    return dt
}

print("=== 拖拽重绘成本基准 ===")
print("（每个 mouseDragged 事件 = redrawAll + refreshDebugView）\n")

// 屏幕尺寸：Retina 下 5K 全屏截图
let configs: [(String, Int, Int)] = [
    ("1080p Retina (2560×1080)", 2560, 1080),
    ("5K   Retina (5120×2160)", 5120, 2160),
]

for (name, w, h) in configs {
    print("【\(name)】 缓冲区 \(w * h * 4 / 1024 / 1024) MB")
    let buf = ProbeBuffer(width: w, height: h)

    let tClear = bench("clear() 单次（固定成本，与对象数无关）") { buf.clear() }

    var tAll: [Int: Double] = [:]
    for n in [1, 10, 50, 200] {
        tAll[n] = bench("redrawAll  \(n) 个对象") { buf.redrawAll(objectCount: n) }
    }

    // 模拟一个拖拽事件的实际代价（redrawAll + 调试面板重绘）
    for n in [10, 50] {
        let t = bench("单个拖拽事件（redrawAll + debugViz, \(n) 对象）") {
            buf.redrawAll(objectCount: n)
            _ = buf.debugVisualization(objectCount: n)
        }
        // 120Hz ProMotion 的帧预算 = 8.33ms
        let budget = 8.333
        let pct = t / budget * 100
        print(String(format: "       └ 占 120Hz 帧预算的 %.1f%%%@",
                     pct, (t > budget ? "  ⚠️ 超预算" : "") as NSString))
    }

    let perObject = (tAll[200]! - tClear) / 200.0
    print(String(format: "  固定成本 %.2f ms  |  每对象增量 %.4f ms", tClear, perObject))
    print(String(format: "  ⇒ 200 对象时固定成本仍占 %.0f%%",
                 tClear / tAll[200]! * 100))
    print("")
}

print("=== buffered 说明 ===")
print("固定成本 = clear()，取决于画布像素数，与标注个数无关。")
print("标注个数只影响 drawObject 之和（每对象约 0.0x ms 量级）。")
