// 打码预览 ↔ 最终对象 必须一致（所见即所得）。
//
// 背景（P0-4）：`RedactionToolHandler` 的 makeObject 处理了 `drawingFromCenter`
// （起点吸附到某个角点时，最终对象是「以起点为中心、尺寸翻倍」的），
// 而 drawPreview 无条件用 `RedactionShape(from:to:)`，**完全忽略了它**。
// 于是用户看到的是一小块预览，松手却打码了另一块**大一倍**的区域 ——
// 对打码这种隐私保护手段来说，这是实打实的错误结果。
//
// 这里用**像素实测**而不是比几何公式：把预览画进离屏位图，量出它实际覆盖的
// 区域，再和最终对象的 sampleRect 比 —— 两条路径真的画出同一块地方才算过。
// （只比内部字段的话，将来任一侧改了公式、另一侧没跟上，探针就测不出来了。）
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

/// 打码预览实际覆盖到的像素矩形（画进透明底位图，量非透明像素的外接框）
func coveredRect(width: Int, height: Int,
                 draw: (CGContext) -> Void) -> CGRect? {
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    draw(ctx)
    guard let data = ctx.data else { return nil }
    let ptr = data.assumingMemoryBound(to: UInt8.self)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let a = ptr[(y * width + x) * 4 + 3]
            if a > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= 0, maxY >= 0 else { return nil }
    // 位图 row 0 在顶，CG 用户空间 y=0 在底 → 翻回来
    return CGRect(x: CGFloat(minX), y: CGFloat(height - 1 - maxY),
                  width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

func makeContext(drawingFromCenter: Bool) -> ToolContext {
    ToolContext(
        color: .red,
        lineWidth: 15,
        lineStyle: .solid,
        arrowStyle: .default,
        drawingFromCenter: drawingFromCenter,
        canvasSize: CGSize(width: 800, height: 600),
        colorKey: 1,
        sourceImage: nil,          // 没有底图 → 打码退化为灰块，正好量它的覆盖范围
        pixelScale: 1,
        detectAttachment: { _ in nil },
        resolveAttachmentPosition: { _ in nil },
        nextStepNumber: { 1 }
    )
}

/// 跑一次「预览」与「最终对象」，返回两者**各自实际画出来的**像素区域。
///
/// 关键是两边都用**画**来量：预览画一次，最终对象自己也画一次。
/// 只比几何字段（sampleRect / width / height）不够 ——
/// 描边类形状的可见墨迹比几何框大半个线宽，拿几何框当判据会误判。
func compare(tool: DrawingTool, start: CGPoint, end: CGPoint,
             drawingFromCenter: Bool) -> (preview: CGRect?, final: CGRect?, obj: CGRect)? {
    let handler = RedactionToolHandler()
    let context = makeContext(drawingFromCenter: drawingFromCenter)

    guard let obj = handler.makeObject(from: start, to: end, tool: tool,
                                       context: context) as? RedactionShape else { return nil }
    let preview = coveredRect(width: 800, height: 600) { ctx in
        handler.drawPreview(from: start, to: end, tool: tool, in: ctx, context: context)
    }
    let final = coveredRect(width: 800, height: 600) { ctx in
        obj.draw(in: ctx)
    }
    return (preview, final, obj.sampleRect)
}

func nearlyEqual(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
        && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
}

print("=== 1. drawingFromCenter = true：预览与落框必须完全重合 ===\n")
do {
    let start = CGPoint(x: 100, y: 100)
    let end = CGPoint(x: 160, y: 130)
    guard let r = compare(tool: .mosaic, start: start, end: end, drawingFromCenter: true),
          let preview = r.preview, let final = r.final else {
        check("能取到预览与最终对象", false); exit(1)
    }
    check("最终对象以起点为中心、尺寸翻倍",
          r.obj == CGRect(x: 40, y: 70, width: 120, height: 60),
          "\(r.obj)")
    check("预览画出来的区域 == 最终对象画出来的区域", nearlyEqual(preview, final),
          "预览 \(preview) / 最终 \(final)")
}

print("\n=== 2. drawingFromCenter = false：预览与落框同样必须重合 ===\n")
do {
    let start = CGPoint(x: 100, y: 100)
    let end = CGPoint(x: 160, y: 130)
    guard let r = compare(tool: .mosaic, start: start, end: end, drawingFromCenter: false),
          let preview = r.preview, let final = r.final else {
        check("能取到预览与最终对象", false); exit(1)
    }
    check("最终对象是两角对角", r.obj == CGRect(x: 100, y: 100, width: 60, height: 30),
          "\(r.obj)")
    check("预览画出来的区域 == 最终对象画出来的区域", nearlyEqual(preview, final),
          "预览 \(preview) / 最终 \(final)")
}

print("\n=== 3. 模糊（blur）同样一致 ===\n")
do {
    let start = CGPoint(x: 200, y: 200)
    let end = CGPoint(x: 260, y: 240)
    guard let r = compare(tool: .blur, start: start, end: end, drawingFromCenter: true),
          let preview = r.preview, let final = r.final else {
        check("能取到预览与最终对象", false); exit(1)
    }
    check("预览画出来的区域 == 最终对象画出来的区域", nearlyEqual(preview, final),
          "预览 \(preview) / 最终 \(final)")
}

print("\n=== 4. 回归：矩形（描边类）预览/落框本来就一致（对照组）===\n")
do {
    // 兄弟 handler 的两条路径共用构造 —— 抽出来当对照组。
    // 矩形是**描边**形状，可见墨迹比几何框大半个线宽，
    // 所以两边都按「实际画出来的像素」比，不拿几何框当判据。
    let handler = RectangleToolHandler()
    let context = makeContext(drawingFromCenter: true)
    let start = CGPoint(x: 100, y: 100), end = CGPoint(x: 160, y: 130)
    guard let obj = handler.makeObject(from: start, to: end, tool: .rectangle,
                                       context: context) as? RectangleShape else {
        check("能取到矩形", false); exit(1)
    }
    let preview = coveredRect(width: 800, height: 600) { ctx in
        handler.drawPreview(from: start, to: end, tool: .rectangle, in: ctx, context: context)
    }
    let final = coveredRect(width: 800, height: 600) { ctx in
        obj.draw(in: ctx)
    }
    guard let p = preview, let f = final else { check("两边都有像素", false); exit(1) }
    check("矩形：预览画出来的区域 == 最终对象画出来的区域", nearlyEqual(p, f),
          "预览 \(p) / 最终 \(f)")
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
