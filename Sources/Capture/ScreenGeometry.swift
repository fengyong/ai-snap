import CoreGraphics

/// 屏幕与图像之间的坐标换算。
///
/// **刻意只依赖 CoreGraphics、不依赖 AppKit**：这样就能脱离 GUI 直接跑探针验证。
/// 这些换算看着简单，但两类错误特别容易发生 ——
/// 缩放倍率的反推、以及 AppKit（左下原点）与图像像素（左上原点）之间的 Y 翻转 ——
/// 而且写错之后的表现往往只是「截出来的图偏了一点」，很难一眼看出。
enum ScreenGeometry {

    // MARK: - AppKit ↔ Quartz

    /// AppKit 屏幕框 → Quartz 矩形。
    ///
    /// `quartzY = 主显示器高度 - (appKitY + height)`
    ///
    /// 用「主显示器高度」而不是本屏高度作基准：AppKit 全局原点在主显示器左下、
    /// Quartz 全局原点在主显示器左上，所以只有主显示器高度这个基准对所有屏幕成立。
    /// 副屏可以是负坐标（位于主屏左侧或上方的屏幕），不要取绝对值。
    static func quartzRect(appKitScreenFrame frame: CGRect,
                           primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX,
               y: primaryScreenHeight - frame.maxY,
               width: frame.width,
               height: frame.height)
    }

    // MARK: - 整屏图 → 选区裁剪

    /// 从「整屏截图」里裁出 AppKit 选区时，对应到图像上的**像素矩形**。
    ///
    /// 两个换算：
    /// 1. **缩放**：整屏图是像素尺寸（Retina 下为点数的 2 倍），选区是点数。
    ///    这里用 `imageSize / screenFrame.size` **反推**实际倍率，而不是假定
    ///    `backingScaleFactor` —— 万一捕获返回的尺寸与预期不符（例如跨屏时
    ///    降到 1x），反推仍然能把选区映射到正确位置。
    /// 2. **Y 翻转**：AppKit 原点在屏幕左下、图像像素原点在左上，因此
    ///    图像 Y = (屏幕上边缘 − 选区上边缘) × 缩放。
    ///
    /// 结果会夹进图像范围并取整，避免浮点误差导致 `CGImage.cropping(to:)` 返回 nil。
    static func pixelRect(appKitRect rect: CGRect,
                          imageSize: CGSize,
                          appKitScreenFrame screenFrame: CGRect) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .null }

        let scaleX = imageSize.width / screenFrame.width
        let scaleY = imageSize.height / screenFrame.height

        let raw = CGRect(
            x: (rect.minX - screenFrame.minX) * scaleX,
            y: (screenFrame.maxY - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let clamped = raw.intersection(imageBounds).integral
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return .null }
        return clamped
    }
}
