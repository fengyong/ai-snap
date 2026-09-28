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
    // 先把这个进程"装扮成真应用"。
    //
    // `setupMainMenu` 现在只在 `NSApp.delegate is AppDelegate` 时才把激活策略切成
    // `.regular` —— 那条判据是为了让**探针进程**（裸可执行文件，默认策略 .prohibited）
    // 不往 Dock 里冒 `run` 图标。所以这里必须装上 delegate 来模拟真应用，
    // 否则下面两条测的就不是真应用的行为了。
    let appDelegate = AppDelegate()
    NSApp.delegate = appDelegate

    let window = AnnotationWindow(image: makeCanvas(200, 150))
    let afterOpen = NSApp.activationPolicy()
    window.close()
    let afterClose = NSApp.activationPolicy()
    NSApp.delegate = nil

    check("开窗后为 .regular（菜单栏可用）", afterOpen == .regular, "rawValue \(afterOpen.rawValue)")
    check("关窗后回到 .accessory（否则 Dock 图标永久残留）",
          afterClose == .accessory, "rawValue \(afterClose.rawValue)")

    // 反向对照：**没有** delegate（= 探针进程的真实身份）时不许切进 Dock
    NSApp.setActivationPolicy(.accessory)
    let probeWindow = AnnotationWindow(image: makeCanvas(120, 90))
    let probeOpen = NSApp.activationPolicy()
    probeWindow.close()
    check("裸进程建窗也不会进 Dock（否则跑一遍套件 Dock 里一串 run 图标）",
          probeOpen != .regular, "rawValue \(probeOpen.rawValue)")
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

// MARK: - 6. 偏好设置窗口的尺寸

print("\n=== 6. 偏好设置窗口必须有个能用的尺寸 ===")
do {
    // 这条守的是一个很隐蔽的坑：container 的约束若缺 bottom，竖直方向无约束，
    // fittingSize.height 退化成 0，紧随其后的 setContentSize 就把窗口压成
    // 一条只剩标题栏的细缝（实测 440×28）——用户看到的现象是"点了偏好设置没反应"。
    // 同一个根因还影响另外两处"出现状态提示后重新适配尺寸"的调用。
    let controller = SettingsWindowController()
    if let window = controller.window {
        let fitting = window.contentView?.fittingSize ?? .zero
        check("contentView 的 fittingSize 高度不为 0（约束完整）",
              fitting.height > 120, "fittingSize \(fitting)")
        check("窗口高度可用（不是只剩标题栏）",
              window.frame.height > 120,
              "\(Int(window.frame.width))×\(Int(window.frame.height))")
        controller.present()
        check("present() 之后窗口可见", window.isVisible)
    } else {
        check("能拿到偏好设置窗口", false)
    }
}

// MARK: - 7. 橡皮擦笔画中途按 Esc

print("\n=== 7. 橡皮擦拖到一半按 Esc：这一笔必须被取消，而不是丢了又不进撤销栈 ===")
do {
    func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }
    func escapeEvent() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\u{1b}",
                         charactersIgnoringModifiers: "\u{1b}",
                         isARepeat: false, keyCode: 53)!
    }
    func drawRect(_ v: AnnotationView, _ a: CGPoint, _ b: CGPoint) {
        v.currentTool = .rectangle
        v.mouseDown(with: mouse(.leftMouseDown, a))
        v.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
        v.mouseUp(with: mouse(.leftMouseUp, b))
    }
    // 矩形 (200,120)-(320,240)：底边 y=120 处描边很宽（线宽+6），(260,120) 必命中
    let onEdge = CGPoint(x: 260, y: 120)

    // A) 中途 Esc → 必须取消这一笔（对象回来）
    let v1 = AnnotationView(image: makeCanvas(600, 400))
    drawRect(v1, CGPoint(x: 200, y: 120), CGPoint(x: 320, y: 240))
    check("先画出一个矩形", v1.objects.count == 1, "对象数 \(v1.objects.count)")

    v1.currentTool = .eraser
    v1.mouseDown(with: mouse(.leftMouseDown, onEdge))     // 命中 → 立刻真删
    let midStroke = v1.objects.count
    v1.keyDown(with: escapeEvent())                      // 还没松手就按 Esc
    v1.mouseUp(with: mouse(.leftMouseUp, onEdge))

    check("拖到一半时对象确实已被真删（说明橡皮擦是实时删）",
          midStroke == 0, "对象数 \(midStroke)")
    // ★ 这条是判别点：不修的话 Esc 让 mouseUp 落进 .idle，对象再也回不来
    check("Esc 之后对象被放回画布", v1.objects.count == 1, "对象数 \(v1.objects.count)")
    check("z 序一并还原", v1.zOrder.count == 1, "zOrder \(v1.zOrder.count)")

    // B) 对照：正常松手 → 真的删掉，而且 ⌘Z 能找回来
    let v2 = AnnotationView(image: makeCanvas(600, 400))
    drawRect(v2, CGPoint(x: 200, y: 120), CGPoint(x: 320, y: 240))
    v2.currentTool = .eraser
    v2.mouseDown(with: mouse(.leftMouseDown, onEdge))
    v2.mouseUp(with: mouse(.leftMouseUp, onEdge))
    check("对照：正常完成的一笔确实删掉了对象", v2.objects.isEmpty, "对象数 \(v2.objects.count)")
    v2.performUndo()
    check("对照：⌘Z 能把这一笔整笔找回来", v2.objects.count == 1, "撤销后对象数 \(v2.objects.count)")

    // C) Esc 取消之后画布状态必须干净：再擦一笔仍然正常
    v1.mouseDown(with: mouse(.leftMouseDown, onEdge))
    v1.mouseUp(with: mouse(.leftMouseUp, onEdge))
    check("Esc 取消后再擦一笔仍然生效（状态没被污染）",
          v1.objects.isEmpty, "对象数 \(v1.objects.count)")
}

// MARK: - 8. 未送出的改动判定 + 「放弃」按钮

print("\n=== 8. 未送出的改动判定 + 「放弃」按钮 ===")
do {
    // 判定用"内容指纹"算出来，所以这里直接改画布状态即可（不必合成鼠标事件）
    let v = AnnotationView(image: makeCanvas(400, 300))
    check("空画布没什么可丢的", !v.hasUnsavedAnnotations)

    let key = v.hitTestBuffer.generateUniqueColorKey()
    v.objects[key] = RectangleShape(from: CGPoint(x: 50, y: 50),
                                    to: CGPoint(x: 150, y: 150),
                                    color: .red, lineWidth: 4, hitTestColorKey: key)
    v.zOrder = [key]
    check("画布上有东西 → 有未送出的改动", v.hasUnsavedAnnotations)

    _ = v.compositeImage()
    check("导出（保存/复制/贴图都会走这里）之后不再提醒", !v.hasUnsavedAnnotations)

    v.objects[key]?.move(by: CGVector(dx: 40, dy: 0))
    check("导出后又改动了 → 重新提醒", v.hasUnsavedAnnotations)

    v.objects.removeValue(forKey: key)
    v.zOrder = []
    check("画完又全部删掉 → 不必提醒", !v.hasUnsavedAnnotations)

    // 「放弃」按钮：存在、是红的、空画布上点它会直接关窗（不弹确认）
    let window = AnnotationWindow(image: makeCanvas(300, 200))
    func allButtons(_ view: NSView) -> [NSButton] {
        var out: [NSButton] = []
        if let b = view as? NSButton { out.append(b) }
        for sub in view.subviews { out.append(contentsOf: allButtons(sub)) }
        return out
    }
    let discard = window.contentView.flatMap { allButtons($0).first { $0.title == "放弃" } }
    check("工具栏里有「放弃」按钮", discard != nil)

    let titleColor = discard?.attributedTitle.attribute(
        .foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    check("「放弃」用红色标题（本工具栏唯一会丢东西的按钮）",
          titleColor == NSColor.systemRed, "\(titleColor.map { "\($0)" } ?? "nil")")

    // 没有未送出内容时不应弹模态框（弹出会阻塞探针），确认函数直接放行
    check("空画布上不需要确认", window.confirmDiscardIfNeeded())
    window.close()
}

// MARK: - 9. OCR 结果面板：自定义选择

print("\n=== 9. OCR 结果面板：选区 ↔ 识别框联动、复制选区/全部 ===")
do {
    // 第二段故意放一个 emoji：它是 1 个字素簇但占 2 个 UTF-16 单元。
    // 区间若用 String.count 算，后面的段会整体错位 —— 这条就是守这个的。
    let items = [
        RecognizedText(text: "第一段 订单号 A123", box: CGRect(x: 10, y: 200, width: 100, height: 20)),
        RecognizedText(text: "第二段 👍 收货人", box: CGRect(x: 10, y: 150, width: 100, height: 20)),
        RecognizedText(text: "第三段 13800000000", box: CGRect(x: 10, y: 100, width: 100, height: 20)),
    ]
    /// 第 i 段在文本里的区间（与实现同算法：UTF-16 长度 + 1 个换行）
    func blockRange(_ i: Int) -> NSRange {
        var location = 0
        for j in 0..<i { location += (items[j].text as NSString).length + 1 }
        return NSRange(location: location, length: (items[i].text as NSString).length)
    }

    let panel = OCRResultWindow(items: items)
    var highlighted: [CGRect] = []
    panel.onHighlightChanged = { highlighted = $0 }

    func findTextView(_ v: NSView) -> NSTextView? {
        if let t = v as? NSTextView { return t }
        for sub in v.subviews { if let t = findTextView(sub) { return t } }
        return nil
    }
    guard let textView = panel.contentView.flatMap({ findTextView($0) }) else {
        check("结果面板里有可选文本视图", false); exit(1)
    }

    check("面板显示的是按阅读顺序拼接的全文",
          textView.string == TextRecognizer.joinedText(items))

    /// 探针里没有事件循环，委托回调不会自己来，手动触发一次
    func selectBlock(_ range: NSRange) {
        textView.selectedRange = range
        (textView.delegate as? NSTextViewDelegate)?
            .textViewDidChangeSelection?(Notification(name: NSTextView.didChangeSelectionNotification,
                                                     object: textView))
    }

    selectBlock(blockRange(1))
    check("只选第 2 段 → 只高亮第 2 段的识别框",
          highlighted == [items[1].box], "高亮 \(highlighted.count) 个")
    check("复制到的是选中的那一段",
          panel.copySelectionOrAllToPasteboard() == items[1].text,
          panel.selectedText ?? "nil")

    selectBlock(NSUnionRange(blockRange(1), blockRange(2)))
    check("跨段选择 → 两段都高亮",
          highlighted == [items[1].box, items[2].box], "高亮 \(highlighted.count) 个")

    // 边界用例：只选第 2 段的**最后一个字**。
    // 第 2 段里那个 emoji 让它"字素簇数 9 ≠ UTF-16 长度 10"；区间若按 String.count
    // 算，这一段会被当成 [13,22)，而选区是 [22,23) → 交集为空 → 高亮不出来。
    // （"整段选择"反而抓不到这个错，因为两边一起错、交集仍然非空。）
    selectBlock(NSRange(location: blockRange(1).upperBound - 1, length: 1))
    check("只选第 2 段最后一个字 → 仍高亮第 2 段（UTF-16 区间算对了）",
          highlighted == [items[1].box], "高亮 \(highlighted.count) 个")

    selectBlock(NSRange(location: 0, length: 0))
    check("没有选区时高亮全部（并提示可拖动选择）",
          highlighted.count == items.count, "高亮 \(highlighted.count) 个")
    check("没有选区时 ⌘C 复制全部",
          panel.copySelectionOrAllToPasteboard() == panel.allText)
    check("「复制全部」不受当前选区影响",
          { selectBlock(blockRange(2)); return panel.copyAllToPasteboard() == panel.allText }())

    // 面板必须是能用的尺寸（偏好设置窗口曾因约束缺 bottom 被压成标题栏）
    check("面板尺寸可用", panel.frame.height > 150,
          "\(Int(panel.frame.width))×\(Int(panel.frame.height))")
    panel.close()
}

// MARK: - 10. 工具栏自动折行

print("\n=== 10. 工具栏自动折成多行（不再是一条 1500+ 的长横带）===")
do {
    // 用小图，让窗口宽度完全由工具栏决定
    let window = AnnotationWindow(image: makeCanvas(120, 90))
    let toolbar = window.contentView?.subviews.first { view in
        view.subviews.contains { $0 is NSButton }
    }

    let rows = Int(((toolbar?.frame.height ?? 0) / ToolbarMetrics.rowHeight).rounded())
    check("工具栏折成多行", rows >= 2, "\(rows) 行，高 \(Int(toolbar?.frame.height ?? 0))")

    // 单行排到 1570 点会变成又长又密的横带，也会把窗口硬撑到 1578 宽 ——
    // 哪怕截图只有 120 点宽。effectiveLimit 把单行上限压到 preferredRowWidth。
    check("窗口不再被工具栏撑得过宽",
          window.frame.width <= ToolbarLayout.preferredRowWidth + 8 + 0.5,
          String(format: "%.0f ≤ %.0f", window.frame.width,
                 ToolbarLayout.preferredRowWidth + 8))

    // 观感上限不能盖过屏幕硬约束：极窄屏必须仍然受屏幕限制
    check("极窄屏仍受屏幕硬约束（观感上限不会放宽它）",
          ToolbarLayout.effectiveLimit(screenVisibleWidth: 600) == 576,
          "\(ToolbarLayout.effectiveLimit(screenVisibleWidth: 600))")
    check("宽屏时被观感上限收住",
          ToolbarLayout.effectiveLimit(screenVisibleWidth: 2560)
            == ToolbarLayout.preferredRowWidth,
          "\(ToolbarLayout.effectiveLimit(screenVisibleWidth: 2560))")

    window.close()
}

// MARK: - 11. 撤销/重做方向显式化（不再靠「对象是否还在表里」反推）

print("\n=== 11. 撤销/重做方向：add/delete 各走各的，不看对象在不在 ===")
do {
    func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }
    func drawRect(_ v: AnnotationView, _ a: CGPoint, _ b: CGPoint) {
        v.currentTool = .rectangle
        v.mouseDown(with: mouse(.leftMouseDown, a))
        v.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
        v.mouseUp(with: mouse(.leftMouseUp, b))
    }

    // A) 添加 → 撤销 → 重做：对象回来，且 z 序一致
    let v = AnnotationView(image: makeCanvas(600, 400))
    drawRect(v, CGPoint(x: 80, y: 80), CGPoint(x: 180, y: 180))
    let keyAfterAdd = v.zOrder.first
    check("添加后对象在画布上", v.objects.count == 1)
    v.performUndo()
    check("撤销添加 → 对象被摘除", v.objects.isEmpty && v.zOrder.isEmpty)
    v.performRedo()
    check("重做添加 → 对象装回", v.objects.count == 1)
    check("重做后 z 序与添加时一致", v.zOrder.first == keyAfterAdd,
          "zOrder \(v.zOrder)")

    // B) 再撤销、再重做一次，确认来回多次不会靠存在性走错分支
    v.performUndo()
    v.performRedo()
    v.performUndo()
    check("多次来回后仍能正确撤销添加", v.objects.isEmpty)
    v.performRedo()
    check("多次来回后仍能正确重做添加", v.objects.count == 1)

    // C) 删除（含多对象）→ 撤销 → 重做
    let v2 = AnnotationView(image: makeCanvas(600, 400))
    drawRect(v2, CGPoint(x: 60, y: 60), CGPoint(x: 140, y: 140))
    drawRect(v2, CGPoint(x: 220, y: 60), CGPoint(x: 300, y: 140))
    let bothKeys = Set(v2.zOrder)
    check("两个矩形都在", v2.objects.count == 2)

    // 选中并删掉其中一个
    let keep = v2.zOrder[0]
    let drop = v2.zOrder[1]
    v2.selectedKey = drop
    v2.deleteSelectedObject()
    check("删掉一个后剩一个", v2.objects.count == 1 && v2.zOrder == [keep])

    v2.performUndo()
    check("撤销删除 → 装回，且 z 序还原",
          v2.objects.count == 2 && Set(v2.zOrder) == bothKeys,
          "objects \(v2.objects.count) z \(v2.zOrder)")
    v2.performRedo()
    check("重做删除 → 再次摘除，且 z 序去到删除后",
          v2.objects.count == 1 && v2.zOrder == [keep],
          "objects \(v2.objects.count) z \(v2.zOrder)")

    // D) 关键判别：删除撤销后，对象「存在」——旧实现会把 redo 的 .delete
    //    误判成「重做删除」（碰巧对）；但「添加撤销后对象不存在」时旧实现走
    //    「重做添加」。两边都对只因 add/delete 恰好互斥。这里再验证：
    //    添加撤销（对象不在）→ 重做添加后，再撤销添加，对象应再次不在。
    v.performUndo() // 撤销重做的添加
    check("添加链路：undo → redo → undo 后对象不在", v.objects.isEmpty)
    v.performRedo()
    check("添加链路：再来一次 redo 对象又在", v.objects.count == 1)
}

// MARK: - 12. 序号可重排（删中间后其余续上）

print("\n=== 12. 序号标注可重排：删掉中间一个，剩下的续上 1、2… ===")
do {
    func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }
    let v = AnnotationView(image: makeCanvas(600, 400))
    v.currentTool = .step
    for (i, p) in [CGPoint(x: 100, y: 100),
                   CGPoint(x: 200, y: 100),
                   CGPoint(x: 300, y: 100)].enumerated() {
        v.mouseDown(with: mouse(.leftMouseDown, p))
        v.mouseUp(with: mouse(.leftMouseUp, p))
        let badges = v.zOrder.compactMap { v.objects[$0] as? StepBadge }
        check("放置第 \(i + 1) 个序号，编号为 \(i + 1)",
              badges.last?.number == i + 1,
              "实际 \(badges.last?.number ?? -1)")
    }

    // 删掉中间那个（number == 2）
    let middleKey = v.zOrder.compactMap { key -> UInt32? in
        (v.objects[key] as? StepBadge)?.number == 2 ? key : nil
    }.first!
    v.selectedKey = middleKey
    v.deleteSelectedObject()

    let after = v.zOrder.compactMap { v.objects[$0] as? StepBadge }.map(\.number)
    check("删中间后剩余重排为 1、2（而不是 1、3）", after == [1, 2], "实际 \(after)")

    v.performUndo()
    let restored = v.zOrder.compactMap { v.objects[$0] as? StepBadge }.map(\.number)
    check("撤销删除后又变回 1、2、3", restored == [1, 2, 3], "实际 \(restored)")

    v.performRedo()
    let redone = v.zOrder.compactMap { v.objects[$0] as? StepBadge }.map(\.number)
    check("重做删除后仍是 1、2", redone == [1, 2], "实际 \(redone)")

    // 再放一个：应接在后面成为 3
    v.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 100)))
    v.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 100)))
    let extended = v.zOrder.compactMap { v.objects[$0] as? StepBadge }.map(\.number)
    check("重排后再新建接在末尾（1、2、3）", extended == [1, 2, 3], "实际 \(extended)")
}

// MARK: - 13. 贴图透明区鼠标穿透

print("\n=== 13. 贴图：透明像素上点击穿过，不透明区仍可点中 ===")
do {
    // 左半不透明、右半全透明的图
    let size = NSSize(width: 100, height: 100)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: 50, height: 100).fill()
    image.unlockFocus()

    let pin = PinWindow(image: image,
                        frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    pin.hasShadow = false
    guard let content = pin.contentView else {
        check("能拿到贴图内容视图", false); exit(1)
    }

    // 不透明半边：hitTest 应命中内容视图
    let opaqueHit = content.hitTest(NSPoint(x: 25, y: 50))
    check("不透明区能点中贴图", opaqueHit === content,
          "hit = \(opaqueHit.map { "\(type(of: $0))" } ?? "nil")")

    // 透明半边：hitTest 应返回 nil（事件落到下层）
    let clearHit = content.hitTest(NSPoint(x: 75, y: 50))
    check("透明区点击穿过（hitTest 为 nil）", clearHit == nil,
          "hit = \(clearHit.map { "\(type(of: $0))" } ?? "nil")")

    // 边界：刚好在中线附近仍应按像素判定，不整块拒收
    let nearSeam = content.hitTest(NSPoint(x: 48, y: 50))
    check("中线左侧（不透明）仍命中", nearSeam === content,
          "hit = \(nearSeam.map { "\(type(of: $0))" } ?? "nil")")

    // 完全不透明的普通截图：任意点都应命中（与旧行为一致）
    let opaqueOnly = NSImage(size: size)
    opaqueOnly.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(origin: .zero, size: size).fill()
    opaqueOnly.unlockFocus()
    let pin2 = PinWindow(image: opaqueOnly,
                         frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    pin2.hasShadow = false
    let centerHit = pin2.contentView?.hitTest(NSPoint(x: 50, y: 50))
    check("普通不透明截图行为不变（到处都能点中）", centerHit != nil,
          "hit = \(centerHit.map { "\(type(of: $0))" } ?? "nil")")

    pin.close()
    pin2.close()
}

// MARK: - 14. 符号键直选全部 12 个工具

print("\n=== 14. 数字键 1–9 与 0 / - / = 直选全部 12 个工具 ===")
do {
    func findAnnotationView(_ v: NSView) -> AnnotationView? {
        if let a = v as? AnnotationView { return a }
        for sub in v.subviews { if let a = findAnnotationView(sub) { return a } }
        return nil
    }
    let window = AnnotationWindow(image: makeCanvas(200, 200))
    guard let view = window.contentView.flatMap({ findAnnotationView($0) }) else {
        check("能拿到标注画布", false); exit(1)
    }
    func key(_ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: 0)!
    }

    // 1 → 箭头
    view.keyDown(with: key("1"))
    check("1 → 箭头", view.currentTool == .arrow, "\(view.currentTool)")
    // 9 → 马赛克（第 9 个）
    view.keyDown(with: key("9"))
    check("9 → 马赛克", view.currentTool == .mosaic, "\(view.currentTool)")
    // 0 / - / = → 第 10–12 个（旧实现到 9 就断了）
    view.keyDown(with: key("0"))
    check("0 → 模糊", view.currentTool == .blur, "\(view.currentTool)")
    view.keyDown(with: key("-"))
    check("- → 橡皮", view.currentTool == .eraser, "\(view.currentTool)")
    view.keyDown(with: key("="))
    check("= → 取色", view.currentTool == .picker, "\(view.currentTool)")

    // 非直选键不应抢走事件改工具
    let before = view.currentTool
    view.keyDown(with: key("x"))
    check("无关字符不改工具", view.currentTool == before, "\(view.currentTool)")
    window.close()
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
