// 形状状态指纹探针（O11，2026-11-11）。
//
// 场景：画布的「有没有未送出的改动」判定（`hasUnsavedAnnotations`）以前靠**画布
// 单方面枚举字段** —— 中心、旋转、包围盒、颜色、文字。形状新增一个可变字段
// （线型、贴纸类型、放大倍数、序号、打码参数…），画布不会自动知道，于是那次改动
// 对指纹**完全不可见**，关窗时就不再提醒用户还有没存的东西。
//
// 错的方向：漏判的后果是**关窗不提醒**（用户以为存住了，实际丢的是整次标注）。
// 这类错不会被任何崩溃暴露 —— 只是某次改动悄悄不生效了。
//
// 现在改成每个形状自己报自己的指纹（`AnnotationObject.stateFingerprint`，
// **协议里没有默认实现** —— 新形状不表态就编译不过），画布只负责组合
// z序 + 对象键 + 形状自报的指纹。
//
// 钉住的事实：
//   §1 逐字段：对 10 个形状 × 各自**全部**可变字段，改一个 → 指纹必须变
//   §2 同状态同指纹 / 异状态异指纹：指纹要能区分不同的画布内容
//   §3 画布级：以前漏掉的字段（线型 / 贴纸类型 / 放大倍数 / 序号 / 打码参数）
//      现在必须能让 `hasUnsavedAnnotations` 变 true —— 而**原来就能认出来的改动
//      仍然要认得出来**（不许为了补漏而把旧覆盖弄丢）
//
//      run_probe fingerprint_probe "${ALL_SOURCES[@]}"
import Cocoa

setbuf(stdout, nil)

var failures = 0
var count = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    count += 1
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

_ = NSApplication.shared

/// 断言「改动某一个可变字段 → 指纹变化」。
///
/// 每个字段都用**全新的实例**单独试 —— 否则前一个字段的改动会留在对象上，
/// 后面的断言就分不清究竟是哪个字段起的作用。
///
/// 这里传具体类型（而不是 `any AnnotationObject`）：字段的改法本来就随形状而异，
/// 泛型化反而要写一堆 `as?` 强转 —— 那正是要消掉的东西。
func checkField<T: AnnotationObject>(_ label: String,
                                     _ make: () -> T,
                                     _ mutate: (inout T) -> Void) {
    let before = make().stateFingerprint
    var obj = make()
    mutate(&obj)
    let after = obj.stateFingerprint
    check("改「\(label)」→ 指纹变化", before != after,
          "before \(before) / after \(after)")
}

print("=== 1. 逐字段：每个可变字段都必须改变指纹 ===\n")

print("-- 箭头 --")
do {
    func make() -> Arrow {
        Arrow(startPoint: CGPoint(x: 10, y: 10), endPoint: CGPoint(x: 100, y: 60),
              color: .black, lineWidth: 3, hitTestColorKey: 1)
    }
    checkField("起点", make) { $0.startPoint = CGPoint(x: 12, y: 10) }
    checkField("终点", make) { $0.endPoint = CGPoint(x: 100, y: 64) }
    checkField("线宽", make) { $0.lineWidth = 9 }
    checkField("颜色", make) { $0.color = .red }
    checkField("箭头样式", make) {
        $0.style = ArrowStyle(headType: .diamond, tailType: .circle, lineStyle: .dashed,
                               headLength: 14, headAngle: .pi / 6)
    }
    checkField("起点附着", make) {
        $0.startAttachment = Attachment(parentKey: 7, anchorType: .perimeter(parameter: 0.5))
    }
    checkField("终点附着", make) {
        $0.endAttachment = Attachment(parentKey: 7, anchorType: .snapPoint(index: 2))
    }
}

print("\n-- 矩形 --")
do {
    func make() -> RectangleShape {
        RectangleShape(center: CGPoint(x: 100, y: 100), width: 80, height: 40,
                       color: .black, lineWidth: 2, hitTestColorKey: 2)
    }
    checkField("中心", make) { $0.center = CGPoint(x: 104, y: 100) }
    checkField("宽", make) { $0.width = 96 }
    checkField("高", make) { $0.height = 52 }
    checkField("旋转", make) { $0.rotation = 0.4 }
    checkField("颜色", make) { $0.color = .blue }
    checkField("线宽", make) { $0.lineWidth = 8 }
    // 下面两项是**旧实现漏掉**的：包围盒不随线型/圆角变
    checkField("线型", make) { $0.lineStyle = .dashed }
    checkField("圆角", make) { $0.cornerRadius = 12 }
}

print("\n-- 圆 --")
do {
    func make() -> CircleShape {
        CircleShape(center: CGPoint(x: 100, y: 100), radiusX: 40, radiusY: 25,
                    color: .black, lineWidth: 2, hitTestColorKey: 3)
    }
    checkField("中心", make) { $0.center = CGPoint(x: 104, y: 100) }
    checkField("横半径", make) { $0.radiusX = 48 }
    checkField("纵半径", make) { $0.radiusY = 33 }
    checkField("旋转", make) { $0.rotation = 0.4 }
    checkField("颜色", make) { $0.color = .blue }
    checkField("线宽", make) { $0.lineWidth = 8 }
    checkField("线型", make) { $0.lineStyle = .dotted }
}

print("\n-- 贴纸 --")
do {
    func make() -> StampObject {
        StampObject(center: CGPoint(x: 100, y: 100), size: 32,
                    stampType: .checkmark, color: .systemRed, hitTestColorKey: 4)
    }
    checkField("中心", make) { $0.center = CGPoint(x: 104, y: 100) }
    checkField("尺寸", make) { $0.size = 44 }
    checkField("旋转", make) { $0.rotation = 0.4 }
    checkField("颜色", make) { $0.color = .blue }
    // 旧实现漏掉：贴纸类型换了，包围盒与颜色都不变
    checkField("贴纸类型", make) { $0.stampType = .exclamation }
}

print("\n-- 序号徽章 --")
do {
    func make() -> StepBadge {
        StepBadge(center: CGPoint(x: 100, y: 100), number: 1, radius: 18,
                  color: .systemRed, rotation: 0, hitTestColorKey: 5)
    }
    checkField("中心", make) { $0.center = CGPoint(x: 104, y: 100) }
    checkField("半径", make) { $0.radius = 26 }
    checkField("旋转", make) { $0.rotation = 0.4 }
    checkField("颜色", make) { $0.color = .blue }
    // 旧实现漏掉：序号变了，其余量一个都不动
    checkField("序号", make) { $0.number = 7 }
}

print("\n-- 文字 --")
do {
    func make() -> TextShape {
        TextShape(center: CGPoint(x: 100, y: 100), text: "你好", fontSize: 20,
                  color: .systemRed, rotation: 0, hitTestColorKey: 6)
    }
    checkField("中心", make) { $0.center = CGPoint(x: 104, y: 100) }
    checkField("文字", make) { $0.text = "换了内容" }
    checkField("字号", make) { $0.fontSize = 32 }
    checkField("旋转", make) { $0.rotation = 0.4 }
    checkField("颜色", make) { $0.color = .blue }
}

print("\n-- 自由笔画 --")
do {
    func make() -> FreehandShape {
        FreehandShape(points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)],
                      color: .black, lineWidth: 4, isMarker: false, hitTestColorKey: 7)
    }
    checkField("笔迹点集", make) {
        $0.points = [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40), CGPoint(x: 90, y: 70)]
    }
    checkField("颜色", make) { $0.color = .blue }
    checkField("线宽", make) { $0.lineWidth = 12 }
    // 旧实现漏掉：画笔与马克笔的线宽/透明度都不同，是用户看得见的差别
    checkField("画笔/马克笔", make) { $0.isMarker = true }
    checkField("旋转", make) { $0.rotation = 0.4 }
}

print("\n-- 放大镜 --")
do {
    func make() -> MagnifierShape {
        MagnifierShape(center: CGPoint(x: 100, y: 100), radius: 60, zoom: 2.5,
                       color: .black, lineWidth: 3, hitTestColorKey: 8)
    }
    checkField("中心", make) { $0.center = CGPoint(x: 104, y: 100) }
    checkField("半径", make) { $0.radius = 80 }
    checkField("旋转", make) { $0.rotation = 0.4 }
    checkField("颜色", make) { $0.color = .blue }
    checkField("线宽", make) { $0.lineWidth = 9 }
    // 旧实现漏掉：倍数变了，镜面取样区域就变了，其余量一个都不动
    checkField("放大倍数", make) { $0.zoom = 4 }
}

print("\n-- 聚光灯 --")
do {
    func make() -> SpotlightShape {
        SpotlightShape(center: CGPoint(x: 100, y: 100), width: 120, height: 60,
                       color: .black, cornerRadius: 8, hitTestColorKey: 9)
    }
    checkField("中心", make) { $0.center = CGPoint(x: 104, y: 100) }
    checkField("宽", make) { $0.width = 150 }
    checkField("高", make) { $0.height = 90 }
    checkField("旋转", make) { $0.rotation = 0.4 }
    checkField("颜色", make) { $0.color = .blue }
    // 旧实现漏掉：圆角变了，遮罩形状就变了
    checkField("圆角", make) { $0.cornerRadius = 20 }
}

print("\n-- 打码 --")
do {
    func make() -> RedactionShape {
        RedactionShape(center: CGPoint(x: 100, y: 100), width: 120, height: 60,
                       style: .mosaic(blockSize: 8), hitTestColorKey: 10)
    }
    checkField("中心", make) { $0.center = CGPoint(x: 104, y: 100) }
    checkField("宽", make) { $0.width = 150 }
    checkField("高", make) { $0.height = 90 }
    checkField("旋转", make) { $0.rotation = 0.4 }
    // 旧实现漏掉：打码参数变了，其余量一个都不动 —— 而这恰恰最该被记住
    checkField("打码参数", make) { $0.style = .blur(radius: 18) }
}

print("\n=== 2. 指纹要能区分内容：同状态同指纹，异状态异指纹 ===\n")
do {
    let a = RectangleShape(center: CGPoint(x: 100, y: 100), width: 80, height: 40,
                            color: .black, hitTestColorKey: 20)
    let b = RectangleShape(center: CGPoint(x: 100, y: 100), width: 80, height: 40,
                            color: .black, hitTestColorKey: 21)
    check("同样内容的两个形状指纹相同",
          a.stateFingerprint == b.stateFingerprint,
          "\(a.stateFingerprint) vs \(b.stateFingerprint)")

    b.width = 81
    check("内容不同则指纹不同",
          a.stateFingerprint != b.stateFingerprint,
          "\(a.stateFingerprint) vs \(b.stateFingerprint)")
}

print("\n=== 3. 画布级：漏掉的字段现在能触发「有未送出的改动」 ===\n")
do {
    func blankCanvas(_ w: CGFloat, _ h: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        image.unlockFocus()
        return image
    }

    let view = AnnotationView(image: blankCanvas(400, 200))
    let key = view.hitTestBuffer.generateUniqueColorKey()
    let rect = RectangleShape(center: CGPoint(x: 100, y: 100), width: 80, height: 40,
                               color: .black, hitTestColorKey: key)
    view.objects[key] = rect
    view.zOrder = [key]

    view.markContentExported()
    check("送出之后没有未送出的改动", !view.hasUnsavedAnnotations)

    // 旧实现**认得出来**的改动 —— 不许为了补漏把旧覆盖弄丢
    rect.lineWidth = 9
    check("改线宽 → 判定为有未送出的改动（旧覆盖仍在）", view.hasUnsavedAnnotations)

    view.markContentExported()
    rect.lineStyle = .dashed
    check("改线型 → 判定为有未送出的改动（旧实现漏掉这项）", view.hasUnsavedAnnotations)

    view.markContentExported()
    rect.center = CGPoint(x: 140, y: 100)
    check("移动 → 判定为有未送出的改动（旧覆盖仍在）", view.hasUnsavedAnnotations)

    view.markContentExported()
    rect.color = .blue
    check("改色 → 判定为有未送出的改动（旧覆盖仍在）", view.hasUnsavedAnnotations)

    // 放大镜的倍数：整条链路上最容易漏的一项
    let key2 = view.hitTestBuffer.generateUniqueColorKey()
    let mag = MagnifierShape(center: CGPoint(x: 250, y: 100), radius: 60, zoom: 2.5,
                              color: .black, lineWidth: 3, hitTestColorKey: key2)
    view.objects[key2] = mag
    view.zOrder = [key, key2]
    view.markContentExported()
    mag.zoom = 4
    check("改放大倍数 → 判定为有未送出的改动（旧实现漏掉这项）", view.hasUnsavedAnnotations)
}

print()
if failures == 0 {
    print("通过 \(count) 项，失败 0 项")
} else {
    print("通过 \(count - failures) 项，失败 \(failures) 项")
    exit(1)
}
