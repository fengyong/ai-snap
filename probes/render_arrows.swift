import Cocoa

//  探针 12 — 箭头样式对照图（肉眼检查渲染质量）
//
//  输出 /tmp/aisnap-arrows/arrows.png：6 种预设 × 6 种线宽的网格。
//  用它可以一眼看出"头部是否被箭杆吞掉""开放头是否有断口"这类纯观感问题。

@main
struct RenderArrows {
    static func main() {
        bootstrapApp()
        let widths: [CGFloat] = [1, 2, 4, 8, 15, 25]
        let presets = ArrowStyle.allPresets
        let names = ArrowStyle.presetNames
        let cellW: CGFloat = 260, cellH: CGFloat = 92, pad: CGFloat = 46
        let W = pad + cellW * CGFloat(widths.count)
        let H = pad + cellH * CGFloat(presets.count) + 30

        let image = NSImage(size: NSSize(width: W, height: H))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()
        let ctx = NSGraphicsContext.current!.cgContext
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                    .foregroundColor: NSColor.darkGray]
        for (c, w) in widths.enumerated() {
            ("\(Int(w))px" as NSString).draw(at: NSPoint(x: pad + CGFloat(c) * cellW + 4, y: H - 24),
                                             withAttributes: attrs)
        }
        for (r, style) in presets.enumerated() {
            let y = H - 40 - CGFloat(r + 1) * cellH + 24
            (names[r] as NSString).draw(at: NSPoint(x: 6, y: y + 26), withAttributes: attrs)
            for (c, w) in widths.enumerated() {
                let x0 = pad + CGFloat(c) * cellW + 16
                Arrow(startPoint: CGPoint(x: x0, y: y + 18),
                      endPoint: CGPoint(x: x0 + cellW - 60, y: y + 52),
                      color: .systemRed, lineWidth: w, hitTestColorKey: 0, style: style)
                    .draw(in: ctx)
            }
        }
        image.unlockFocus()

        let dir = "/tmp/aisnap-arrows"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir + "/arrows.png")
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        // 客观检查：默认参数（15px 实心）下，箭头头部必须比箭杆明显更宽
        let lw: CGFloat = 15
        let head = Arrow(startPoint: .zero, endPoint: CGPoint(x: 100, y: 0),
                         color: .red, lineWidth: lw, hitTestColorKey: 0, style: .default)
        let headWidth = 2 * head.effectiveHeadLength * sin(ArrowStyle.default.headAngle)
        if headWidth > lw * 1.5 {
            Probe.ok("ARROW-1", "默认 15px 线宽下箭头头部宽度明显大于箭杆（不再被吞掉）",
                     String(format: "头部宽 %.0fpt vs 箭杆 %.0fpt", headWidth, lw))
        } else {
            Probe.bug("ARROW-1", "箭头头部仍被箭杆吞掉",
                      String(format: "头部宽 %.0fpt vs 箭杆 %.0fpt", headWidth, lw),
                      expect: "头部宽度应 ≥ 箭杆的 1.5 倍")
        }
        Probe.note("ARROW-2", "对照图已写入 \(url.path)（6 样式 × 6 线宽）")

        // 命中层必须覆盖尖端（否则端点抓不住）
        let img = NSImage(size: NSSize(width: 200, height: 60))
        img.lockFocus()
        let c = NSGraphicsContext.current!.cgContext
        head.endPoint = CGPoint(x: 180, y: 30)
        head.drawHitTest(in: c, color: .white)
        img.unlockFocus()
        let tipLum = luminance(img, at: CGPoint(x: 179, y: 30))
        if tipLum > 0.5 {
            Probe.ok("ARROW-3", "命中层覆盖箭头尖端", String(format: "尖端像素亮度 %.2f", tipLum))
        } else {
            Probe.bug("ARROW-3", "命中层没有覆盖尖端（箭头端点会抓不住）",
                      String(format: "尖端像素亮度 %.2f", tipLum), expect: "应 > 0.5")
        }
        Probe.finish("render_arrows")
    }
}
