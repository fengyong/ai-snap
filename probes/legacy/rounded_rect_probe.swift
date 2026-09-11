// 实测：对每个线宽二分找出「角点从有线变切掉」的翻转半径，再检验候选取值是否高于它
import Cocoa

let W = 400, H = 300
let rect = CGRect(x: 50, y: 50, width: 300, height: 200)

func cornerPainted(radius: CGFloat, lineWidth: CGFloat) -> Bool {
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                      bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setShouldAntialias(false)
    c.setAllowsAntialiasing(false)
    c.setFillColor(NSColor.black.cgColor)
    c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    c.setStrokeColor(NSColor.white.cgColor)
    c.setLineWidth(lineWidth)
    c.setLineJoin(.round)
    c.setLineDash(phase: 0, lengths: [])
    c.setLineCap(.round)
    if radius > 0 {
        let r = min(radius, min(rect.width, rect.height) / 2)
        c.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        c.strokePath()
    } else {
        c.stroke(rect)
    }
    let ptr = c.data!.assumingMemoryBound(to: UInt8.self)
    let o = (H - 1 - 50) * W * 4 + 50 * 4
    return ptr[o] > 0 || ptr[o + 1] > 0 || ptr[o + 2] > 0
}

/// 二分找最小的「切掉」半径
func flipPoint(lineWidth: CGFloat) -> CGFloat {
    var lo: CGFloat = 0, hi: CGFloat = 200
    for _ in 0..<24 {
        let mid = (lo + hi) / 2
        if cornerPainted(radius: mid, lineWidth: lineWidth) { lo = mid } else { hi = mid }
    }
    return hi
}

print("=== 实测翻转点（角点从「有线」变「切掉」的最小半径）===\n")
var flips: [CGFloat: CGFloat] = [:]
for lw in [CGFloat(2), 4, 8, 15, 30] {
    let f = flipPoint(lineWidth: lw)
    flips[lw] = f
    print(String(format: "  线宽 %-3.0f → 翻转点 r = %5.1f   （= %.2f × 线宽）",
                 lw, f, f / lw))
}

print("\n=== 候选取值对比（需高于翻转点才算「圆角可见」）===\n")
print("  线宽    翻转点   max(12,2×lw)   max(12,3×lw)")
for lw in [CGFloat(2), 4, 8, 15, 30] {
    let f = flips[lw]!
    let a = max(12, lw * 2), b = max(12, lw * 3)
    print(String(format: "  %-6.0f  %5.1f    %5.1f %@      %5.1f %@",
                 lw, f, a, (a > f ? "✅" : "❌") as NSString,
                 b, (b > f ? "✅" : "❌") as NSString))
}
