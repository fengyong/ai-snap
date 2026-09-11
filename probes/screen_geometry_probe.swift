// ScreenGeometry 的真实行为测试（链接真实源码，只依赖 CoreGraphics）
import CoreGraphics

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}
func eq(_ a: CGRect, _ b: CGRect, tol: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol
        && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
}
func fmt(_ r: CGRect) -> String {
    String(format: "(%.1f, %.1f, %.1f, %.1f)", r.minX, r.minY, r.width, r.height)
}

// 沿用上一轮实测得到的那套真实显示器布局（3 块 2x 屏）
let primary = CGRect(x: 0, y: 0, width: 2560, height: 1080)
let above = CGRect(x: -803, y: -982, width: 1512, height: 982)
let left = CGRect(x: -2048, y: 288, width: 2048, height: 1152)
let primaryHeight: CGFloat = 1080

print("=== 1. AppKit 屏框 → Quartz 矩形 ===\n")
print("   （实测已知的对照：AppKit (-803,-982,1512,982) ↔ Quartz (-803,1080,1512,982)）\n")

let qPrimary = ScreenGeometry.quartzRect(appKitScreenFrame: primary, primaryScreenHeight: primaryHeight)
check("主屏保持 (0,0,2560,1080)", eq(qPrimary, primary), fmt(qPrimary))

let qAbove = ScreenGeometry.quartzRect(appKitScreenFrame: above, primaryScreenHeight: primaryHeight)
check("上方屏 → (-803, 1080, 1512, 982)", eq(qAbove, CGRect(x: -803, y: 1080, width: 1512, height: 982)),
      fmt(qAbove))

let qLeft = ScreenGeometry.quartzRect(appKitScreenFrame: left, primaryScreenHeight: primaryHeight)
check("左侧屏 → (-2048, -360, 2048, 1152)", eq(qLeft, CGRect(x: -2048, y: -360, width: 2048, height: 1152)),
      fmt(qLeft))
print("   验算：1080 - (-982 + 982) = 1080 ✅   1080 - (288 + 1152) = -360 ✅")

print("\n=== 2. 像素矩形：缩放反推 ===\n")
let img2x = CGSize(width: 5120, height: 2160)     // 主屏 2x
let sel = CGRect(x: 100, y: 200, width: 300, height: 400)

let p2x = ScreenGeometry.pixelRect(appKitRect: sel, imageSize: img2x, appKitScreenFrame: primary)
check("2x：缩放为 2、尺寸翻倍且 Y 翻转",
      eq(p2x, CGRect(x: 200, y: 960, width: 600, height: 800)), fmt(p2x))
print("   验算：x = 100×2 = 200；y = (屏高 1080 − 选区上边缘 600) × 2 = 960；" +
      "尺寸 300×2 / 400×2")

print("\n=== 3. 同样的图但按 1x 解释（反推应得 1.0）===\n")
let img1x = CGSize(width: 2560, height: 1080)
let p1x = ScreenGeometry.pixelRect(appKitRect: sel, imageSize: img1x, appKitScreenFrame: primary)
check("1x：与选区等尺寸", p1x.width == sel.width && p1x.height == sel.height,
      fmt(p1x))
check("1x：Y = 屏幕高 - 选区上边缘",
      abs(p1x.minY - (primary.height - sel.maxY)) < 0.01, fmt(p1x))

print("\n=== 4. 副屏（负坐标）上的选区 ===\n")
// 左侧屏 AppKit (-2048, 288, 2048, 1152)，Quartz 图上 y 从 0 起
let leftImg = CGSize(width: 4096, height: 2304)
let leftSel = CGRect(x: -2000, y: 300, width: 500, height: 400)
let pLeft = ScreenGeometry.pixelRect(appKitRect: leftSel, imageSize: leftImg, appKitScreenFrame: left)
check("X 相对屏左边缘：( -2000 - (-2048) ) × 2 = 96", abs(pLeft.minX - 96) < 0.01, fmt(pLeft))
check("Y 距屏上边缘：(288+1152 - 700) × 2 = 1480",
      abs(pLeft.minY - ((left.maxY - leftSel.maxY) * 2)) < 0.01, fmt(pLeft))

print("\n=== 5. 缩放不一致时以反推为准（跨屏降级 1x 的场景）===\n")
// 有人以为跨屏会返回 2x，但实测会降到 1x —— 反推能自动适配
let degraded = ScreenGeometry.pixelRect(appKitRect: sel, imageSize: CGSize(width: 2560, height: 1080),
                                        appKitScreenFrame: primary)
check("图像实际 1x → 按 1x 映射（不按假定 2x）",
      degraded.width == sel.width, fmt(degraded))

print("\n=== 6. 裁剪到图像边界内 ===\n")
let outside = CGRect(x: 2500, y: 1000, width: 500, height: 500)   // 部分越出屏幕
let pClip = ScreenGeometry.pixelRect(appKitRect: outside, imageSize: img2x, appKitScreenFrame: primary)
check("越界部分被裁掉", pClip.maxX <= img2x.width + 0.01 && pClip.maxY <= img2x.height + 0.01,
      fmt(pClip))
check("仍在图像内、非 null", !pClip.isNull && pClip.width > 0 && pClip.height > 0, fmt(pClip))

let fullyOutside = CGRect(x: 9999, y: 9999, width: 100, height: 100)
check("完全越界 → .null（调用方据此报错）",
      ScreenGeometry.pixelRect(appKitRect: fullyOutside, imageSize: img2x,
                               appKitScreenFrame: primary).isNull)

print("\n=== 7. 退化输入不应崩 ===\n")
check("屏幕宽为 0 → .null",
      ScreenGeometry.pixelRect(appKitRect: sel, imageSize: img2x,
                               appKitScreenFrame: CGRect(x: 0, y: 0, width: 0, height: 100)).isNull)
check("图像尺寸为 0 → .null",
      ScreenGeometry.pixelRect(appKitRect: sel, imageSize: .zero,
                               appKitScreenFrame: primary).isNull)

print("\n=== 结果 ===")
if failures == 0 { print("全部通过") } else { print("\(failures) 项失败"); exit(1) }
