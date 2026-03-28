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
        // 24-bit RGB 最多支持 16,777,215 个唯一对象，超出后回绕
        if nextColorIndex > 0xFFFFFF {
            nextColorIndex = 1
        }
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

        // CGBitmapContext 像素数据从上到下存储（row 0 = 顶部），
        // 但绘图坐标系 y=0 在底部，因此需要翻转 Y
        let flippedY = height - 1 - y
        let bytesPerRow = context.bytesPerRow
        let offset = flippedY * bytesPerRow + x * 4

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

    /// 生成 Layer B 的可视化调试图像
    /// 真实 Layer B 的颜色极暗（#000001, #000002...），肉眼不可见。
    /// 此方法用相同的 drawHitTest 逻辑，但映射到明亮的颜色，揭示幕后的魔术。
    func debugVisualization(objects: [UInt32: any AnnotationObject], zOrder: [UInt32]) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // 模拟 Layer B 的关键设置：关闭抗锯齿
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)

        // 深色背景（代替 Layer B 的纯黑 #000000）
        ctx.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // 每个对象用黄金比例分配色相，保证相邻对象颜色区分度最大
        let goldenRatio: CGFloat = 0.618033988749895
        for (i, key) in zOrder.enumerated() {
            guard let obj = objects[key] else { continue }
            let hue = (CGFloat(i + 1) * goldenRatio).truncatingRemainder(dividingBy: 1.0)
            let brightColor = NSColor(hue: hue, saturation: 0.85, brightness: 0.95, alpha: 1.0)
            obj.drawHitTest(in: ctx, color: brightColor)
        }

        image.unlockFocus()
        return image
    }
}
