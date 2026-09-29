import CoreGraphics
import Foundation

/// 滚动长截图的拼接算法（纯 CoreGraphics，无 AppKit，可离屏探针）。
///
/// ## 算法：行投影 + 归一化互相关
///
/// 把两张图灰度化，每行求平均亮度得到「行投影」序列；B 的前 k 行与 A 的末 k 行
/// 是同一内容的两次曝光（滚动重叠区），对 k ∈ [minOverlap, maxSearch] 求
/// 两条子序列的 Pearson 相关，峰值即重叠行数。
///
/// 选行投影而不是逐像素模板匹配：
/// - 400×300 灰度图逐像素滑窗是 ~10⁵ 量级的乘加，行投影把它压到 ~10³；
/// - 对水平方向 1-2px 的滚动错位（窗口边框/滚动条微差）天然不敏感 ——
///   逐像素匹配会在这种噪声上掉相关峰值，行投影的行均值几乎不动。
///
/// 已知边界（功能实现时要处理，spike 已验证算法本身）：
/// 纯色/渐变内容没有可相关的结构 → 相关曲线平坦，靠峰值显著性判定返回 nil；
/// 无限滚动列表（内容回收复用）会出现假峰 —— 功能层要允许用户手动修正。
enum ImageStitch {

    /// B 的前 `overlap` 行与 A 的末 `overlap` 行重叠。找不到可靠峰值返回 nil。
    /// - Parameters:
    ///   - maxSearch: 最大搜索的重叠行数（滚动一屏的量级；越大越慢）。
    ///   - minOverlap: 低于这个重叠量的相关性没有统计意义（行均值的偶然相似）。
    static func verticalOverlap(imageA: CGImage, imageB: CGImage,
                                maxSearch: Int = 600, minOverlap: Int = 12) -> Int? {
        let rowsA = rowMeans(imageA)
        let rowsB = rowMeans(imageB)
        guard let rowsA, let rowsB else { return nil }

        let upper = min(maxSearch, rowsA.count, rowsB.count)
        guard upper > minOverlap else { return nil }

        var bestK: Int?
        var bestScore = threshold
        for k in minOverlap...upper {
            // A 的末 k 行 vs B 的前 k 行
            let tailA = rowsA.suffix(k)
            let headB = rowsB.prefix(k)
            let score = pearson(tailA, headB)
            if score > bestScore {
                bestScore = score
                bestK = k
            }
        }
        return bestK
    }

    /// 拼接：A 全部行 + B 去掉前 `overlap` 行的部分。
    /// `overlap` 越界时返回 nil（调用方应先经 `verticalOverlap` 取得）。
    static func stitchVertical(_ a: CGImage, _ b: CGImage, overlap: Int) -> CGImage? {
        guard overlap >= 0, overlap < b.height,
              a.width == b.width else { return nil }
        let outHeight = a.height + (b.height - overlap)
        guard let ctx = CGContext(
            data: nil, width: a.width, height: outHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CG 坐标系左下原点：A 画在上半，B 整幅画在下半 ——
        // B 的前 overlap 行被 A 盖住？不：B 在 y=0 起画、高度含 overlap，
        // 与 A（y 从 b.height-overlap 起）恰好重叠 overlap 行且内容一致，
        // 所以直接整幅画 B 即可，无需自己裁 B 的头
        ctx.draw(a, in: CGRect(x: 0, y: CGFloat(b.height - overlap),
                               width: CGFloat(a.width), height: CGFloat(a.height)))
        ctx.draw(b, in: CGRect(x: 0, y: 0,
                               width: CGFloat(b.width), height: CGFloat(b.height)))
        return ctx.makeImage()
    }

    // MARK: - 内部

    /// 相关峰值必须超过这个数才算「找到了」。合成纹理 ≈ 1.0；真实 UI 截图
    /// 的滚动重叠区通常 > 0.98；纯色/无重叠 < 0.5。留 0.85 兜住压缩噪声。
    private static let threshold: Double = 0.85

    /// 每行的平均亮度（0...1）。RGBA 逐字节累计 —— 400×300 图 ~0.5MB，
    /// 一次线性扫描即可，不值得上 vImage。
    static func rowMeans(_ image: CGImage) -> [Double]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)

        var sums = [Double](repeating: 0, count: height)
        for y in 0..<height {
            let rowStart = y * width * 4
            var total = 0
            for x in 0..<width {
                let o = rowStart + x * 4
                // 与 alpha 无关的亮度近似（截图内容基本不透明，premultiplied 直接加即可）
                total += Int(bytes[o]) + Int(bytes[o + 1]) + Int(bytes[o + 2])
            }
            sums[y] = Double(total) / (Double(width) * 3.0 * 255.0)
        }
        return sums
    }

    /// Pearson 相关系数。任一侧零方差（纯色段）返回 -1 —— 永远选不中。
    static func pearson(_ x: ArraySlice<Double>, _ y: ArraySlice<Double>) -> Double {
        let n = x.count
        guard n == y.count, n > 1 else { return -1 }
        let xs = Array(x), ys = Array(y)
        let meanX = xs.reduce(0, +) / Double(n)
        let meanY = ys.reduce(0, +) / Double(n)
        var cov = 0.0, varX = 0.0, varY = 0.0
        for i in 0..<n {
            let dx = xs[i] - meanX, dy = ys[i] - meanY
            cov += dx * dy
            varX += dx * dx
            varY += dy * dy
        }
        guard varX > 0, varY > 0 else { return -1 }
        return cov / (varX.squareRoot() * varY.squareRoot())
    }
}
