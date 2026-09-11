// RectPerimeter 与 TextShape 的真实行为测试（链接真实 Models.swift）
import Cocoa

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}
func approx(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat) -> Bool { abs(a - b) <= tol }

// ─────────────────────────────────────────────
print("=== 1. RectPerimeter 互逆性：参数 → 点 → 参数 ===\n")
print("   （这是最关键的检查：两处分段不一致时，箭头会吸到与鼠标位置不符的点）\n")

let center = CGPoint(x: 400, y: 300)
let size = CGSize(width: 300, height: 200)

for rotation in [CGFloat(0), 0.3, -0.7, 1.2] {
    var worst: CGFloat = 0
    // 避开正好落在角上的参数（那里两套分段都可能命中，属正常歧义）
    let probes: [CGFloat] = [0.03, 0.10, 0.20, 0.32, 0.45, 0.58, 0.70, 0.83, 0.94]
    for p in probes {
        let pt = RectPerimeter.point(at: p, center: center, size: size, rotation: rotation)
        let back = RectPerimeter.parameter(for: pt, center: center, size: size, rotation: rotation)
        worst = max(worst, abs(back - p))
    }
    let label = String(format: "旋转 %.2f rad：最大往返误差 %.5f", rotation, worst)
    check(label, worst < 0.005, String(format: "%.5f", worst))
}

print("\n=== 2. 分段约定：四个特殊参数应落在四条边上 ===\n")
// 未旋转时：下边(y=-hh) → 右边(x=+hw) → 上边(y=+hh) → 左边(x=-hw)
let bottom = RectPerimeter.point(at: 0.05, center: center, size: size, rotation: 0)
check("0.05 → 下边（y < center）", bottom.y < center.y,
      String(format: "(%.1f, %.1f)", bottom.x, bottom.y))
let rightEdge = RectPerimeter.point(at: 0.30, center: center, size: size, rotation: 0)
check("0.30 → 右边（x ≈ +hw）", approx(rightEdge.x, center.x + size.width / 2, 0.01),
      String(format: "(%.1f, %.1f)", rightEdge.x, rightEdge.y))
let top = RectPerimeter.point(at: 0.60, center: center, size: size, rotation: 0)
check("0.60 → 上边（y > center）", top.y > center.y,
      String(format: "(%.1f, %.1f)", top.x, top.y))
let leftEdge = RectPerimeter.point(at: 0.85, center: center, size: size, rotation: 0)
check("0.85 → 左边（x ≈ -hw）", approx(leftEdge.x, center.x - size.width / 2, 0.01),
      String(format: "(%.1f, %.1f)", leftEdge.x, leftEdge.y))

print("\n=== 3. 退化输入 ===\n")
check("尺寸为 0 → parameter 返回 0",
      RectPerimeter.parameter(for: center, center: center, size: .zero, rotation: 0) == 0)
check("尺寸为 0 → point 返回 center",
      RectPerimeter.point(at: 0.5, center: center, size: .zero, rotation: 0) == center)

// ─────────────────────────────────────────────
print("\n=== 4. TextShape：尺寸由内容与字号推导 ===\n")

let short = TextShape(center: CGPoint(x: 100, y: 100), text: "Hi",
                      fontSize: 20, hitTestColorKey: 1)
let long = TextShape(center: CGPoint(x: 100, y: 100), text: "这是一段明显更长的文字内容",
                     fontSize: 20, hitTestColorKey: 2)
check("文字越长尺寸越宽", long.contentSize.width > short.contentSize.width,
      String(format: "%.1f > %.1f", long.contentSize.width, short.contentSize.width))

let small = TextShape(center: .zero, text: "测试", fontSize: 12, hitTestColorKey: 3)
let big = TextShape(center: .zero, text: "测试", fontSize: 40, hitTestColorKey: 4)
check("字号越大尺寸越大", big.contentSize.height > small.contentSize.height,
      String(format: "%.1f > %.1f", big.contentSize.height, small.contentSize.height))

// 多行：换行会让高度增长
let oneLine = TextShape(center: .zero, text: "第一行", fontSize: 20, hitTestColorKey: 5)
let twoLines = TextShape(center: .zero, text: "第一行\n第二行", fontSize: 20, hitTestColorKey: 6)
check("多行文字高度翻倍左右",
      twoLines.contentSize.height > oneLine.contentSize.height * 1.6,
      String(format: "%.1f vs %.1f", twoLines.contentSize.height, oneLine.contentSize.height))

print("\n=== 5. TextShape：缩放作用在字号上 ===\n")
let shape = TextShape(center: .zero, text: "缩我", fontSize: 20, hitTestColorKey: 7)
shape.scale(by: 2)
check("缩放 2× → 字号 40", approx(shape.fontSize, 40, 0.001), "\(shape.fontSize)")
shape.scale(by: 0.5)
check("再缩 0.5× → 字号 20", approx(shape.fontSize, 20, 0.001), "\(shape.fontSize)")
shape.scale(by: 0.0001)
check("字号有下限 8（不会缩到看不见）", shape.fontSize >= 8, "\(shape.fontSize)")
shape.scale(by: 100000)
check("字号有上限 300", shape.fontSize <= 300, "\(shape.fontSize)")

print("\n=== 6. TextShape：包围盒与旋转 ===\n")
let t = TextShape(center: CGPoint(x: 200, y: 200), text: "旋转测试",
                  fontSize: 24, hitTestColorKey: 8)
let boxBefore = t.boundingBox
check("未旋转时包围盒含中心点", boxBefore.contains(CGPoint(x: 200, y: 200)),
      String(format: "%.0f×%.0f", boxBefore.width, boxBefore.height))

t.rotate(by: .pi / 4)
let boxAfter = t.boundingBox
// 注意：宽矩形旋转 45° 后**宽度会变小**（100 → 96），高度变大（36 → 96）—— 这是
// 外接矩形的正确行为（AABB = w|cosθ|+h|sinθ| 与 w|sinθ|+h|cosθ|），
// 所以判据用「面积变大」而不是「两边都变大」。
check("旋转 45° 后外接矩形面积变大",
      boxAfter.width * boxAfter.height > boxBefore.width * boxBefore.height,
      String(format: "%.0f×%.0f (%.0f) → %.0f×%.0f (%.0f)",
             boxBefore.width, boxBefore.height, boxBefore.width * boxBefore.height,
             boxAfter.width, boxAfter.height, boxAfter.width * boxAfter.height))
check("旋转后仍含中心点", boxAfter.contains(CGPoint(x: 200, y: 200)))

print("\n=== 7. TextShape：周长参数与矩形同套约定 ===\n")
let tx = TextShape(center: CGPoint(x: 500, y: 400), text: "文字", fontSize: 20,
                   hitTestColorKey: 9)
var txWorst: CGFloat = 0
for p in [CGFloat(0.05), 0.2, 0.35, 0.5, 0.65, 0.8, 0.95] {
    let pt = tx.pointOnPerimeter(at: p)
    let back = RectPerimeter.parameter(for: pt, center: tx.center,
                                       size: tx.contentSize, rotation: tx.rotation)
    txWorst = max(txWorst, abs(back - p))
}
check(String(format: "文字周长往返误差 %.5f", txWorst), txWorst < 0.005)

print("\n=== 结果 ===")
if failures == 0 { print("全部通过") } else { print("\(failures) 项失败"); exit(1) }
