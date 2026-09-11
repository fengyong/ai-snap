import CoreGraphics
import CoreImage
import Foundation

/// 打码用的图像处理：马赛克（像素化）与高斯模糊。
///
/// **刻意只依赖 CoreGraphics / CoreImage，不依赖 AppKit**：这类处理的正确性只能靠
/// 像素验证（块平均是不是真的平均、模糊区边缘有没有发暗、放大有没有被插值糊掉），
/// 脱离 GUI 才能直接拿真实参数跑离屏探针。
enum ImageRedaction {

    // MARK: - 马赛克

    /// 降采样到「每块一个像素」—— 马赛克的最小表示。
    ///
    /// 返回的图像只有 `ceil(宽/块) × ceil(高/块)` 那么大；显示时用**最近邻**放大回
    /// 目标尺寸，就得到硬边色块。之所以不在这里直接放大、而是把「小图」交给调用方：
    /// - 小图极小（整屏打码也就几十×几十），可以长期缓存；
    /// - 若在这里放大，每帧都要新建一幅整幅大小的位图，光分配和拷贝就吃掉帧预算。
    ///
    /// ## ★ 插值质量必须用 `.medium`（这是实测出来的，反直觉）
    ///
    /// 直觉会选 `.high` —— 但 `.high` 是 **Lanczos 型核，带振铃**：它既不做面积平均，
    /// 又会把相邻块的内容"过冲"进来。离屏实测（50/50 黑白条纹按块 20 降采样，
    /// 正确答案是每块 128）：
    ///
    /// | 插值 | 条纹四块的结果 | 左黑右白交界两块 | 判定 |
    /// |---|---|---|---|
    /// | `.high`   | 61 133 122 194 | 21 / 234 | ❌ 振铃 + 串色 |
    /// | `.medium` | 128 128 128 128 | 0 / 255 | ✅ 精确面积平均、不串色 |
    /// | `.low`    | 0 0 0 0 | 0 / 255 | ❌ 等于取块首像素 |
    /// | 手写整数平均 | 127 127 127 127 | 0 / 255 | ✅（但整屏 5.45ms） |
    /// | vImage   | 115 131 124 140 | 17 / 238 | ❌ 也不是精确箱式 |
    ///
    /// `.high` 的振铃不只是"不好看"：块的代表色可能**偏向块内某个高对比细节**
    /// （比如一小段文字），那正是打码要消除的东西。所以这里取 `.medium`。
    /// 它同时还是最快的（整屏 0.04ms —— CG 内部会缓存同一张图的缩放结果）。
    static func blockAverages(_ image: CGImage, blockSize: Int) -> CGImage? {
        let block = max(2, blockSize)
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        let cols = max(1, Int((Double(width) / Double(block)).rounded(.up)))
        let rows = max(1, Int((Double(height) / Double(block)).rounded(.up)))

        guard let small = makeBitmap(width: cols, height: rows, quality: .medium) else {
            return nil
        }
        small.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        return small.makeImage()
    }

    /// 完整马赛克：块平均 + 最近邻放大回原始尺寸。
    ///
    /// 交互路径（拖拽预览、画布绘制）应该用 `blockAverages` 拿小图自己缩放；
    /// 这个组合版用于离屏验证与「就是要一张成品图」的场合。
    static func pixelate(_ image: CGImage, blockSize: Int) -> CGImage? {
        guard let small = blockAverages(image, blockSize: blockSize) else { return nil }
        return scale(small, to: CGSize(width: image.width, height: image.height),
                     quality: .none)
    }

    /// 把图像缩放到指定尺寸。
    ///
    /// 打码贴图**统一在「画布点分辨率」下生成**，`draw` 时就能按 1:1 贴上去，
    /// 每帧只做一次拷贝。若缓存的是像素分辨率（Retina 上大两倍），每帧都要多付一次
    /// 重采样 —— 同进程交错实测（整屏 2560×1600 打码，20 轮中位）：
    ///
    ///   每帧把小图放大铺满   6.83 ms
    ///   每帧 1:1 贴整幅图     0.38 ms   ← 18×
    ///
    /// 两个数字都不是从"理论上应该更快"推出来的，所以不做任何假设。
    static func scale(_ image: CGImage, to size: CGSize,
                      quality: CGInterpolationQuality) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let ctx = makeBitmap(width: width, height: height, quality: quality) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - 高斯模糊

    /// 高斯模糊。`radius` 以**像素**为单位（调用方按像素倍率把点换算过来）。
    ///
    /// 先 `clampedToExtent()` 再裁回原范围：高斯核会采样到给定范围之外，若不先钳制
    /// 边缘像素，边缘处会取到「透明」而被晕开 —— 表现是打码区四周出现一圈发亮/发暗
    /// 的边，而且区域越小越明显。
    static func blur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let clampedRadius = max(0.5, radius)
        let input = CIImage(cgImage: image)
        let blurred = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur",
                            parameters: [kCIInputRadiusKey: clampedRadius])
            .cropped(to: input.extent)
        return sharedContext.createCGImage(blurred, from: input.extent)
    }

    /// `CIContext` 的创建代价在毫秒级，每次打码都新建一个会直接吃掉帧预算。
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Helpers

    private static func makeBitmap(width: Int, height: Int,
                                   quality: CGInterpolationQuality) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.interpolationQuality = quality
        return ctx
    }
}
