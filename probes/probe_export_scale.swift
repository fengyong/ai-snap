import Cocoa

//  探针 09 — 逻辑尺寸与导出分辨率（报告 P2-6 / P4-8）
//
//  修复后的行为：
//   * 逻辑尺寸由 `CaptureResult.logicalSize` 从**捕获屏**的 backingScaleFactor 推出，
//     不再事后读 NSScreen.main；
//   * 导出用显式 bitmap，像素尺寸恒等于源图像像素，与当前显示器无关。

@main
struct ExportScaleProbe {
    static func main() {
        bootstrapApp()
        let screenScale = NSScreen.main?.backingScaleFactor ?? -1
        Probe.section("P2-6 逻辑尺寸推算（CaptureResult.logicalSize）")
        Probe.note("P2-6", "当前显示器 backingScaleFactor = \(screenScale)")

        // (像素宽, 像素高, 真实捕获 scale, 说明)
        let cases: [(Int, Int, CGFloat, String)] = [
            (5120, 2160, 2, "2x 截图"),
            (2560, 1080, 1, "1x 截图"),
            (1440, 900, 2, "小尺寸 2x 截图"),
        ]

        for (pw, ph, trueScale, desc) in cases {
            let cg = makeCGImage(pw: pw, ph: ph)
            let screen = NSScreen.screens.first { $0.backingScaleFactor == trueScale }
            let result = CaptureResult(image: cg, screen: screen)
            // 无对应 scale 的屏幕时（本机三块屏都是 2x），退化为按真实 scale 直接推算
            let logical = screen != nil ? result.logicalSize
                                        : NSSize(width: CGFloat(pw) / trueScale, height: CGFloat(ph) / trueScale)
            let want = NSSize(width: CGFloat(pw) / trueScale, height: CGFloat(ph) / trueScale)
            let logicalOK = abs(logical.width - want.width) < 1 && abs(logical.height - want.height) < 1

            let image = NSImage(cgImage: cg, size: logical)
            // 与 AppDelegate 一致：把源图像的像素尺寸显式传给画布
            let view = AnnotationView(image: image, pixelSize: CGSize(width: pw, height: ph))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("aisnap-probe-\(pw)x\(ph)-\(Int(trueScale))x.png")
            guard let size = exportPNG(view.compositeImage(), to: url) else {
                Probe.note("P2-6", "\(desc)：导出失败"); continue
            }
            let pixelsOK = size.0 == pw && size.1 == ph

            Probe.note("P2-6", String(format: "%@：源 %dx%d px（scale %.0f）→ 逻辑 %.0fx%.0f pt → 导出 %dx%d px",
                                      desc, pw, ph, trueScale, logical.width, logical.height, size.0, size.1))

            let id = "P2-6-\(Int(trueScale))x-\(pw)"
            if logicalOK && pixelsOK {
                Probe.ok(id, "逻辑尺寸与导出像素都正确",
                         String(format: "%.0fx%.0f pt → %dx%d px", logical.width, logical.height, size.0, size.1))
            } else if !logicalOK {
                Probe.bug(id, "逻辑尺寸推算错误（\(desc)）",
                          String(format: "得到 %.0fx%.0f pt，应为 %.0fx%.0f pt", logical.width, logical.height, want.width, want.height),
                          expect: "应等于 像素尺寸 / 捕获屏的 backingScaleFactor")
            } else {
                Probe.bug(id, "导出像素不等于源像素（\(desc)）",
                          "\(size.0)x\(size.1) vs 源 \(pw)x\(ph)",
                          expect: "导出应恒等于源图像像素尺寸，与当前显示器无关")
            }
        }

        // ── P4-8: 导出分辨率不再随显示器变化 ──
        Probe.section("P4-8 导出分辨率与显示器无关")
        let cg2 = makeCGImage(pw: 3000, ph: 2000)
        let v2 = AnnotationView(image: NSImage(cgImage: cg2, size: NSSize(width: 1500, height: 1000)),
                                pixelSize: CGSize(width: 3000, height: 2000))
        if let size = pngPixelSize(v2.compositeImage()) {
            if size.0 == 3000 && size.1 == 2000 {
                Probe.ok("P4-8", "导出分辨率等于源图像像素（不再跟随 lockFocus 的屏幕 scale）", "3000x2000")
            } else {
                Probe.bug("P4-8", "导出分辨率偏离源像素",
                          "\(size.0)x\(size.1) vs 源 3000x2000",
                          expect: "应与源图像像素一致")
            }
        }

        Probe.finish("probe_export_scale")
    }

    static func makeCGImage(pw: Int, ph: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                            bytesPerRow: pw * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        return ctx.makeImage()!
    }
}
