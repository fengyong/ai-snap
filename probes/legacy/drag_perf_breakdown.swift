// (A) 按实际缓冲区尺寸(2560×1080 点)重测拖拽成本拆解
// (B) 顺带验一个疑点：compositeImage 的 lockFocus 会不会把 Retina 截图降成 1x
import Cocoa

let W = 2560, H = 1080, N = 10

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(false)
    ctx.setAllowsAntialiasing(false)
    return ctx
}

func drawObjects(_ ctx: CGContext, _ n: Int, _ w: Int, _ h: Int, bright: Bool) {
    for i in 0..<n {
        let c: NSColor = bright
            ? NSColor(hue: (CGFloat(i + 1) * 0.618033988749895).truncatingRemainder(dividingBy: 1.0),
                      saturation: 0.85, brightness: 0.95, alpha: 1.0)
            : NSColor(red: CGFloat((i * 37) % 255) / 255.0,
                      green: CGFloat((i * 91) % 255) / 255.0,
                      blue: CGFloat((i * 53) % 255) / 255.0, alpha: 1.0)
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(21)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 40, y: 40))
        ctx.addLine(to: CGPoint(x: CGFloat(w) - 40, y: CGFloat(h) - 40))
        ctx.strokePath()
        ctx.setFillColor(c.cgColor)
        ctx.fillEllipse(in: CGRect(x: 100, y: 100, width: 60, height: 60))
    }
}

func bench(_ label: String, iterations: Int = 50, _ body: () -> Void) {
    for _ in 0..<3 { body() }
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations { body() }
    let dt = (CFAbsoluteTimeGetCurrent() - t0) / Double(iterations) * 1000.0
    print(String(format: "  %-42@ %7.2f ms", label as NSString, dt))
}

let ctx = makeContext(W, H)
let size = NSSize(width: W, height: H)

print("=== (A) 拖拽事件成本拆解 · 实际缓冲区 2560×1080 · \(N) 对象 ===")
print("    120Hz 帧预算 8.33ms / 60Hz 16.7ms\n")

bench("① Layer B：整画布 fill") {
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
}
bench("② Layer B：\(N) 个对象描线+填充") { drawObjects(ctx, N, W, H, bright: false) }
bench("③ Layer B 重绘（= redrawAll, ①+②）") {
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    drawObjects(ctx, N, W, H, bright: false)
}
bench("④ 调试面板：NSImage lock/unlock 空转") {
    let img = NSImage(size: size); img.lockFocus(); img.unlockFocus()
}
bench("⑤ 调试面板：整画布 fill") {
    let img = NSImage(size: size)
    img.lockFocus()
    if let c = NSGraphicsContext.current?.cgContext {
        c.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
        c.fill(CGRect(origin: .zero, size: size))
    }
    img.unlockFocus()
}
bench("⑥ 调试面板：= debugVisualization（⑤+对象）") {
    let img = NSImage(size: size)
    img.lockFocus()
    if let c = NSGraphicsContext.current?.cgContext {
        c.setShouldAntialias(false)
        c.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
        c.fill(CGRect(origin: .zero, size: size))
        drawObjects(c, N, W, H, bright: true)
    }
    img.unlockFocus()
}
bench("⑦ 对照：同尺寸裸 CGContext 做同样的事") {
    ctx.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    drawObjects(ctx, N, W, H, bright: true)
}

print("\n=== (B) 导出分辨率疑点：lockFocus 后 backing scale ===")

// 模拟一份 Retina 截图：5120×2160 像素，逻辑尺寸 2560×1080 点
let srcCtx = makeContext(5120, 2160)
srcCtx.setFillColor(NSColor.systemRed.cgColor)
srcCtx.fill(CGRect(x: 0, y: 0, width: 5120, height: 2160))
guard let srcCG = srcCtx.makeImage() else { exit(1) }
print("  源 CGImage：\(srcCG.width)×\(srcCG.height) px")

let nsSrc = NSImage(cgImage: srcCG, size: NSSize(width: 2560, height: 1080))
print("  源 NSImage.size：\(Int(nsSrc.size.width))×\(Int(nsSrc.size.height)) pt")

// 复刻 compositeImage 的做法
let out = NSImage(size: nsSrc.size)
out.lockFocus()
nsSrc.draw(in: NSRect(origin: .zero, size: nsSrc.size))
if let c = NSGraphicsContext.current?.cgContext {
    c.setFillColor(NSColor.systemBlue.cgColor)
    c.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
}
out.unlockFocus()

if let rep = out.representations.first {
    print("  → compositeImage 产物：\(rep.pixelsWide)×\(rep.pixelsHigh) px  (\(type(of: rep)))")
    if rep.pixelsWide == 5120 {
        print("     ✅ 保住 Retina")
    } else {
        print("     ⚠️ 掉到 \(rep.pixelsWide)px —— 相对源图 5120px 少了一半像素")
    }
}

// 对照：直接画进指定像素尺寸的 CGContext
let fixed = makeContext(5120, 2160)
fixed.draw(srcCG, in: CGRect(x: 0, y: 0, width: 5120, height: 2160))
if let img = fixed.makeImage() {
    print("  对照（裸 CGContext 5120×2160）：\(img.width)×\(img.height) px")
}
