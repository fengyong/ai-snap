// 验证：虚/点线矩形真的有间隙，且命中区（drawHitTest）仍为实线
import Cocoa

let W = 400, H = 300

func ctx(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setShouldAntialias(false)
    c.setAllowsAntialiasing(false)
    return c
}

// 与 Models.swift 的 LineStyle.apply 同一份逻辑
func apply(_ style: String, lw: CGFloat, _ c: CGContext) {
    switch style {
    case "solid":
        c.setLineDash(phase: 0, lengths: []); c.setLineCap(.round)
    case "dashed":
        c.setLineDash(phase: 0, lengths: [lw * 3, lw * 2]); c.setLineCap(.butt)
    default:
        c.setLineDash(phase: 0, lengths: [1, lw * 2]); c.setLineCap(.round)
    }
}

/// 复刻 RectangleShape.draw
func drawRect(_ c: CGContext, style: String, lw: CGFloat, solid: Bool) {
    c.setStrokeColor(NSColor.white.cgColor)
    c.setLineWidth(solid ? lw + 6 : lw)
    c.setLineJoin(.round)
    if solid {
        c.setLineDash(phase: 0, lengths: []); c.setLineCap(.round)
    } else {
        apply(style, lw: lw, c)
    }
    c.stroke(CGRect(x: 50, y: 50, width: 300, height: 200))
}

/// 沿矩形的上边缘采样，统计落在「空白」的比例
func gapRatio(style: String, lw: CGFloat, solid: Bool) -> Double {
    let c = ctx(W, H)
    c.setFillColor(NSColor.black.cgColor)
    c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    drawRect(c, style: style, lw: lw, solid: solid)

    guard let data = c.data else { return -1 }
    let ptr = data.assumingMemoryBound(to: UInt8.self)
    let bpr = c.bytesPerRow
    // 矩形上边缘 y=250（CG 坐标，y 向上）；行索引需翻转
    let y = 250
    let row = H - 1 - y
    var empty = 0, total = 0
    for x in 60..<340 {
        let o = row * bpr + x * 4
        total += 1
        if ptr[o] == 0 && ptr[o + 1] == 0 && ptr[o + 2] == 0 { empty += 1 }
    }
    return Double(empty) / Double(total)
}

// 同样沿上边缘统计矩形内部（y=150）应为全黑，用于确认采样点没错
print("=== 矩形上边缘 (y=250) 的空白像素占比 ===\n")
for lw in [CGFloat(2), 5, 15, 30] {
    let solid = gapRatio(style: "solid", lw: lw, solid: false)
    let dashed = gapRatio(style: "dashed", lw: lw, solid: false)
    let dotted = gapRatio(style: "dotted", lw: lw, solid: false)
    let pick = gapRatio(style: "dashed", lw: lw, solid: true)
    print(String(format: "线宽 %2.0f  实线 %.0f%%   虚线 %.0f%%   点线 %.0f%% | 命中区(强制实线) %.0f%%",
                 lw, solid * 100, dashed * 100, dotted * 100, pick * 100))
}
print("\n期望：实线与命中区为 0%（整条连续可点），虚/点线有显著间隙")
