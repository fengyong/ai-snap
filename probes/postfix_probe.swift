import Cocoa

// 针对本轮修复的回归探针。
//
// 断言都锚在"用户可观察的后果"上，不复刻实现细节 —— 否则修好之后
// 断言反而会拦住正确的实现。
//
//   1. 预发布版本号比较遵循 SemVer（1.0.0-alpha < 1.0.0-beta）
//   2. OCR 阅读顺序是确定的全序（结果与输入顺序无关）
//   3. 聚光灯重叠区不再被重复压暗；导出图不含编辑器虚线边框
//   4. 关闭标注窗口后激活策略回到 .accessory（Dock 图标不残留）
//   5. 打开标注窗口不会覆盖/销毁偏好里已存的画笔颜色

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
}

_ = NSApplication.shared

// MARK: - 工具

func makeCanvas(_ w: CGFloat, _ h: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    image.unlockFocus()
    return image
}

func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
    guard let tiff = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)
}

/// 读某个 AppKit 点（左下原点）的亮度
func luminance(_ image: NSImage, at p: CGPoint) -> CGFloat {
    guard let rep = bitmap(image) else { return -1 }
    let sx = CGFloat(rep.pixelsWide) / max(image.size.width, 1)
    let sy = CGFloat(rep.pixelsHigh) / max(image.size.height, 1)
    let px = Int(p.x * sx), py = Int((image.size.height - p.y - 0.5) * sy)
    guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
          let c = rep.colorAt(x: px, y: py) else { return -1 }
    return (c.redComponent + c.greenComponent + c.blueComponent) / 3
}

/// 数"黄色像素"（聚光灯编辑器虚线的特征色）
func countYellowish(_ image: NSImage) -> Int {
    guard let rep = bitmap(image) else { return -1 }
    var n = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            if r > 0.5, g > 0.35, b < 0.35, (r - b) > 0.3 { n += 1 }
        }
    }
    return n
}

func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    var out: [[T]] = []
    for (i, item) in items.enumerated() {
        var rest = items
        rest.remove(at: i)
        for tail in permutations(rest) { out.append([item] + tail) }
    }
    return out
}

// MARK: - 1. 预发布版本号比较

print("=== 1. 预发布版本号比较（SemVer §11.4）===")
do {
    func v(_ s: String) -> AppVersion { AppVersion(s)! }
    // SemVer 规范里给出的完整优先级链
    check("1.0.0-alpha < 1.0.0-alpha.1", v("1.0.0-alpha") < v("1.0.0-alpha.1"))
    check("1.0.0-alpha.1 < 1.0.0-alpha.beta", v("1.0.0-alpha.1") < v("1.0.0-alpha.beta"))
    check("1.0.0-alpha.beta < 1.0.0-beta", v("1.0.0-alpha.beta") < v("1.0.0-beta"))
    check("1.0.0-beta < 1.0.0-beta.2", v("1.0.0-beta") < v("1.0.0-beta.2"))
    check("1.0.0-beta.2 < 1.0.0-beta.11（数字标识按数值比，不是字典序）",
          v("1.0.0-beta.2") < v("1.0.0-beta.11"))
    check("1.0.0-beta.11 < 1.0.0-rc.1", v("1.0.0-beta.11") < v("1.0.0-rc.1"))
    check("1.0.0-rc.1 < 1.0.0（预发布低于正式）", v("1.0.0-rc.1") < v("1.0.0"))
    // 这一条是回归点：旧实现只存了 isPrerelease 布尔量，两个不同预发布会被判等
    check("1.0.0-alpha ≠ 1.0.0-beta（旧实现判等 → 新预发布版不提示更新）",
          v("1.0.0-alpha") != v("1.0.0-beta"))
    check("1.0.0 == 1.0.0.0（缺位补 0 的行为不受影响）", v("1.0.0") == v("1.0.0.0"))
    check("isPrerelease 标记仍然可用", v("1.0.0-beta").isPrerelease && !v("1.0.0").isPrerelease)
}

// MARK: - 2. OCR 阅读顺序

print("\n=== 2. OCR 阅读顺序：确定的全序 ===")
do {
    let line1 = [RecognizedText(text: "B", box: CGRect(x: 120, y: 200, width: 40, height: 20)),
                 RecognizedText(text: "A", box: CGRect(x: 20, y: 202, width: 40, height: 20))]
    let line2 = [RecognizedText(text: "D", box: CGRect(x: 120, y: 150, width: 40, height: 20)),
                 RecognizedText(text: "C", box: CGRect(x: 20, y: 148, width: 40, height: 20))]
    let ordered = TextRecognizer.readingOrder(line1 + line2).map(\.text).joined()
    check("先上后下、行内先左后右", ordered == "ABCD", ordered)

    // 高度不一的一堆框：旧实现把"半行高容差"写成 sorted(by:) 的比较器，
    // 那个关系不可传递（A~B 同行、B~C 同行，A 与 C 却不同行），
    // 于是结果会随输入顺序变化。改成锚点聚类后是真全序 → 任意排列结果相同。
    //
    // 这组数据是**搜出来的**：在 2 万组随机框里筛"旧实现结果随排列变化、
    // 新实现稳定"的用例，共 722 组命中，这里取第一组。
    // 用它的意义是保证这条断言真的有区分力 —— 随手编一组数据很可能
    // 新旧实现都给出同一个答案，那样的断言是空的（本项目踩过这个坑）。
    //   旧实现：{dacb, dbac, dcba} 三种结果；新实现：稳定 dacb
    let tricky = [
        RecognizedText(text: "a", box: CGRect(x: 81, y: 109, width: 20, height: 20)),
        RecognizedText(text: "b", box: CGRect(x: 64, y: 90, width: 20, height: 40)),
        RecognizedText(text: "c", box: CGRect(x: 98, y: 117, width: 20, height: 8)),
        RecognizedText(text: "d", box: CGRect(x: 14, y: 123, width: 20, height: 8)),
    ]
    let base = TextRecognizer.readingOrder(tricky).map(\.text).joined()
    let perms = permutations(tricky)
    let allSame = perms.allSatisfy {
        TextRecognizer.readingOrder($0).map(\.text).joined() == base
    }
    check("结果与输入顺序无关（共 \(perms.count) 种排列）", allSame, "基准序 \(base)")
}

// MARK: - 3. 聚光灯遮罩

print("\n=== 3. 聚光灯：重叠区不重复压暗 / 导出不含编辑器边框 ===")
do {
    let canvas = AnnotationView(image: makeCanvas(400, 300))
    let key1 = canvas.hitTestBuffer.generateUniqueColorKey()
    let key2 = canvas.hitTestBuffer.generateUniqueColorKey()
    // 两块**重叠**的聚光灯：s1 覆盖 x∈[90,210]，s2 覆盖 x∈[150,270]
    canvas.objects[key1] = SpotlightShape(center: CGPoint(x: 150, y: 150),
                                          width: 120, height: 120, hitTestColorKey: key1)
    canvas.objects[key2] = SpotlightShape(center: CGPoint(x: 210, y: 150),
                                          width: 120, height: 120, hitTestColorKey: key2)
    canvas.zOrder = [key1, key2]

    let composite = canvas.compositeImage()
    // (110,150) 只在 s1 内；(180,150) 在两灯交集里
    let single = luminance(composite, at: CGPoint(x: 110, y: 150))
    let overlap = luminance(composite, at: CGPoint(x: 180, y: 150))
    check("重叠区不比单灯区更暗（旧实现的偶奇裁剪在此变暗）",
          overlap >= single - 0.02,
          String(format: "单灯区 %.3f / 重叠区 %.3f", single, overlap))

    let yellowish = countYellowish(composite)
    check("导出图不含聚光灯编辑器虚线边框", yellowish == 0, "黄色像素 \(yellowish)")

    // 对照：屏幕上（非导出）仍然要画那条虚线，否则用户看不出高亮区在哪
    var onScreenYellow = -1
    if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let img = NSImage(size: canvas.bounds.size)
        img.addRepresentation(rep)
        onScreenYellow = countYellowish(img)
    }
    check("屏幕上仍保留编辑器虚线边框", onScreenYellow > 0, "黄色像素 \(onScreenYellow)")
}

// MARK: - 4. 关窗后的激活策略

print("\n=== 4. 关闭标注窗口后激活策略回到 .accessory ===")
do {
    NSApp.setActivationPolicy(.accessory)
    let window = AnnotationWindow(image: makeCanvas(200, 150))
    let afterOpen = NSApp.activationPolicy()
    window.close()
    let afterClose = NSApp.activationPolicy()

    check("开窗后为 .regular（菜单栏可用）", afterOpen == .regular, "rawValue \(afterOpen.rawValue)")
    check("关窗后回到 .accessory（否则 Dock 图标永久残留）",
          afterClose == .accessory, "rawValue \(afterClose.rawValue)")
}

// MARK: - 5. 画笔颜色不被开窗销毁

print("\n=== 5. 打开标注窗口不会销毁已存的画笔颜色 ===")
do {
    let prefs = Preferences.shared
    let original = prefs.color
    defer { prefs.color = original }        // 无论如何都还原用户真实偏好

    // 挑一个"不是当前调色板第一个"的颜色
    let palette = ColorPalette.allPalettes[prefs.paletteIndex]
    let target = palette.colors.count > 1 ? palette.colors[1] : NSColor.systemBlue
    prefs.color = target
    let beforeHex = Preferences.hexString(from: prefs.color)

    let window = AnnotationWindow(image: makeCanvas(200, 150))
    let afterHex = Preferences.hexString(from: prefs.color)
    window.close()

    check("偏好里的颜色没被开窗改写", afterHex == beforeHex,
          "开窗前 \(beforeHex) → 开窗后 \(afterHex)")
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
