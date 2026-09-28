import CoreGraphics
import Foundation

/// 从一张图里按像素读颜色。
///
/// 只在首次取色时把整幅图重绘进**已知的 RGBA8 布局**，之后每次取色就是 4 次字节读取 ——
/// 取色器每帧要读十几次（放大镜还要读一小片区域），逐次 `cropping` + 新建上下文
/// 会有肉眼可见的延迟。
///
/// **只依赖 CoreGraphics**：分量换算与 HEX 文本是这类代码里最容易写错的部分
/// （取整方式、大小写、前导零、灰度色），脱离 GUI 才好逐个用例验证。
final class ImagePixelSampler {
    let pixelWidth: Int
    let pixelHeight: Int

    /// RGBA8，**左上原点**（与 CGImage 的行序一致，不是 AppKit 的左下原点）
    private let data: [UInt8]

    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        // **一次分配**：先把 Swift 数组建好，再把它的内存交给 CGContext 直接画进去。
        //
        // 原来是 `CGContext(data: nil, ...)` 让 CG 分配一块缓冲、画完再
        // `Array(UnsafeBufferPointer(...))` 拷进 Swift 数组 —— 峰值两份整图 RGBA
        // （Retina 全屏各 60MB+），而且那份拷贝纯属白搬。
        // 现在只有一份，画完直接把它交给 `data`。
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        self.pixelWidth = w
        self.pixelHeight = h
        self.data = buffer
    }

    // MARK: - 坐标换算

    /// 画布点 → 像素坐标。
    ///
    /// 两个换算都要做对：
    /// - **缩放**：倍率用「像素尺寸 ÷ 点尺寸」反推，不假定 `backingScaleFactor`；
    /// - **Y 翻转**：画布原点在左下、图像像素原点在左上。
    ///
    /// 单独抽成静态方法是为了能离屏测 —— 写错的表现只是"取到的颜色偏几个像素"，
    /// 而屏幕上相邻像素常常颜色相近，肉眼根本看不出来。
    static func pixelCoordinate(canvasPoint: CGPoint,
                                canvasSize: CGSize,
                                pixelSize: CGSize) -> (x: Int, y: Int)? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        // 先按画布范围判定是否有效，**含边界**。
        //
        // 边界必须算有效：画布点 (0,0)（左下角）换算出的像素 y 恰好等于图像高度，
        // 直接当越界丢掉的话，沿着图像最下/最右一条边点击永远取不到色 ——
        // 而那恰恰是用户会点到的地方。空转的探针正好抓到了这一条。
        guard canvasPoint.x >= 0, canvasPoint.x <= canvasSize.width,
              canvasPoint.y >= 0, canvasPoint.y <= canvasSize.height else { return nil }

        let scaleX = pixelSize.width / canvasSize.width
        let scaleY = pixelSize.height / canvasSize.height
        let w = Int(pixelSize.width), h = Int(pixelSize.height)

        let x = min(w - 1, max(0, Int((canvasPoint.x * scaleX).rounded(.down))))
        let y = min(h - 1,
                    max(0, Int(((canvasSize.height - canvasPoint.y) * scaleY).rounded(.down))))
        return (x, y)
    }

    // MARK: - 取色

    func rgb(atPixelX x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard x >= 0, x < pixelWidth, y >= 0, y < pixelHeight else { return nil }
        let i = (y * pixelWidth + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    /// 取一小片像素，供放大镜显示。`side` 为奇数时中心落在正中间。
    func smallImage(centeredAtPixelX cx: Int, y cy: Int, side: Int) -> CGImage? {
        let s = max(1, side)
        guard let ctx = CGContext(data: nil, width: s, height: s,
                                  bitsPerComponent: 8, bytesPerRow: s * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let dst = ctx.data!.bindMemory(to: UInt8.self, capacity: s * s * 4)
        let half = s / 2
        for j in 0..<s {
            for i in 0..<s {
                let x = cx - half + i
                let y = cy - half + j
                let d = (j * s + i) * 4
                if x >= 0, x < pixelWidth, y >= 0, y < pixelHeight {
                    let src = (y * pixelWidth + x) * 4
                    dst[d] = data[src]
                    dst[d + 1] = data[src + 1]
                    dst[d + 2] = data[src + 2]
                    dst[d + 3] = data[src + 3]
                } else {
                    // 越界处填深灰：放大镜在图像边缘时不该出现一块透明
                    dst[d] = 40; dst[d + 1] = 40; dst[d + 2] = 40; dst[d + 3] = 255
                }
            }
        }
        return ctx.makeImage()
    }

    // MARK: - 文本表示

    /// `#RRGGBB`（大写）。分量先夹到 0…255，避免越界色值产生 `#1FF…` 这种非法串。
    static func hex(r: Int, g: Int, b: Int) -> String {
        String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// 便于粘贴到设计稿 / CSS 的十进制写法。
    static func rgbText(r: Int, g: Int, b: Int) -> String {
        "R \(clamp(r))  G \(clamp(g))  B \(clamp(b))"
    }

    private static func clamp(_ v: Int) -> Int { max(0, min(255, v)) }
}
