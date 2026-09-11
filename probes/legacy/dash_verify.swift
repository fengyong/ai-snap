import Cocoa

let width = 600, height = 64
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(false); ctx.setAllowsAntialiasing(false)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

func keyColor(_ k: UInt32) -> CGColor {
    CGColor(red: CGFloat((k >> 16) & 0xFF) / 255, green: CGFloat((k >> 8) & 0xFF) / 255,
            blue: CGFloat(k & 0xFF) / 255, alpha: 1)
}
func readKey(_ x: Int, _ y: Int) -> UInt32 {
    let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let off = (height - 1 - y) * ctx.bytesPerRow + x * 4
    return (UInt32(ptr[off]) << 16) | (UInt32(ptr[off+1]) << 8) | UInt32(ptr[off+2])
}
func sample() -> (miss: Int, total: Int) {
    var miss = 0, total = 0
    for x in 10..<(width - 10) { total += 1; if readKey(x, 32) == 0 { miss += 1 } }
    return (miss, total)
}

let lw: CGFloat = 15

// 1) 视觉层：dashed = butt + [3w, 2w]
ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
ctx.setStrokeColor(keyColor(5)); ctx.setLineWidth(lw)
ctx.setLineCap(.butt); ctx.setLineDash(phase: 0, lengths: [lw * 3, lw * 2])
ctx.move(to: CGPoint(x: 10, y: 32)); ctx.addLine(to: CGPoint(x: width - 10, y: 32)); ctx.strokePath()
let d = sample(); print("视觉 dashed butt+[3w,2w]: 空隙 \(d.miss)/\(d.total) (\(100*d.miss/d.total)%)  期望 ~40%")

// 2) 视觉层：dotted = round + [1, 2w]
ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
ctx.setStrokeColor(keyColor(5)); ctx.setLineWidth(lw)
ctx.setLineCap(.round); ctx.setLineDash(phase: 0, lengths: [1, lw * 2])
ctx.move(to: CGPoint(x: 10, y: 32)); ctx.addLine(to: CGPoint(x: width - 10, y: 32)); ctx.strokePath()
let t = sample(); print("视觉 dotted round+[1,2w]: 空隙 \(t.miss)/\(t.total) (\(100*t.miss/t.total)%)  期望 ~40%")

// 3) picking 层：强制实线（lw + 6, round, 无 dash）
ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
ctx.setStrokeColor(keyColor(5)); ctx.setLineWidth(lw + 6)
ctx.setLineCap(.round); ctx.setLineDash(phase: 0, lengths: [])
ctx.move(to: CGPoint(x: 10, y: 32)); ctx.addLine(to: CGPoint(x: width - 10, y: 32)); ctx.strokePath()
let s = sample(); print("picking 强制实线:       空隙 \(s.miss)/\(s.total)  期望 0（命中区连续）")
