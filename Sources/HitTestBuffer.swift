import Cocoa

/// 隐藏图层 (Layer B) — 用于 Color Picking Hit Test
class HitTestBuffer {
    private(set) var context: CGContext
    private var nextColorIndex: UInt32 = 1  // 0 = 背景(无对象)
    let width: Int
    let height: Int

    init(size: CGSize) {
        width = Int(size.width)
        height = Int(size.height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // 关键：关闭抗锯齿，避免边缘混色导致查找失败
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)

        clear()
    }

    /// 分配一个新的唯一颜色 key
    func generateUniqueColorKey() -> UInt32 {
        let key = nextColorIndex
        nextColorIndex += 1
        return key
    }

    /// 将 UInt32 key 转换为 NSColor (用于在 Layer B 绘制)
    static func colorFromKey(_ key: UInt32) -> NSColor {
        let r = CGFloat((key >> 16) & 0xFF) / 255.0
        let g = CGFloat((key >> 8) & 0xFF) / 255.0
        let b = CGFloat(key & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// 读取指定位置的颜色 key，用于 hit test
    func pickColorKey(at point: CGPoint) -> UInt32 {
        let x = Int(point.x)
        let y = Int(point.y)

        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        guard let data = context.data else { return 0 }

        let bytesPerRow = context.bytesPerRow
        let offset = y * bytesPerRow + x * 4

        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let r = UInt32(ptr[offset])
        let g = UInt32(ptr[offset + 1])
        let b = UInt32(ptr[offset + 2])

        return (r << 16) | (g << 8) | b
    }

    /// 清空缓冲区 (全部置为 0 = 背景)
    func clear() {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// 在 Layer B 上绘制任意标注对象 (使用其唯一颜色，关闭抗锯齿)
    func drawObject(_ object: any AnnotationObject) {
        let pickColor = HitTestBuffer.colorFromKey(object.hitTestColorKey)
        object.drawHitTest(in: context, color: pickColor)
    }

    /// 按 Z 序重绘所有对象到 Layer B
    func redrawAll(objects: [UInt32: any AnnotationObject], zOrder: [UInt32]) {
        clear()
        for key in zOrder {
            if let obj = objects[key] {
                drawObject(obj)
            }
        }
    }
}
