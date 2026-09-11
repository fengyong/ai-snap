import Cocoa

// 工具栏宽度与折行的**集成**验证：构造真实的 AnnotationWindow，量它最终占多宽。
//
// 背景：工具栏用绝对坐标排布，内容涨到 1490 点宽 —— 比常见笔记本屏幕的可见宽度
// （1473）还宽。窗口比屏幕宽 ⇒ 就地编辑只能整体左移 ⇒ 画布离开用户刚框住的选区。
// 现在改成按组折行，窗口宽度必须落回屏幕之内。**这一条就是本文件要守住的底线。**

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func makeImage(_ w: Int, _ h: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor.gray.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    img.unlockFocus()
    return img
}

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
    else { fail += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
}

// 用一个很小的图，让 contentWidth 不参与竞争 —— 于是窗口宽度完全由工具栏决定。
let window = AnnotationWindow(image: makeImage(120, 90))

guard let container = window.contentView,
      let toolbar = container.subviews.first(where: { v in
          v.subviews.contains { $0 is NSButton }
      }) else { print("❌ 找不到工具栏"); exit(1) }

let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
let rowHeight: CGFloat = 48
let rows = Int((toolbar.frame.height / rowHeight).rounded())
let limit = ToolbarLayout.widthLimit(screenVisibleWidth: screen.width)

print("=== 1. 尺寸 ===\n")
print(String(format: "  窗口      %.0f × %.0f", window.frame.width, window.frame.height))
print(String(format: "  工具栏    %.0f × %.0f  →  %d 行", toolbar.frame.width, toolbar.frame.height, rows))
print(String(format: "  屏幕可见   %.0f × %.0f", screen.width, screen.height))
print(String(format: "  折行上限   %.0f", limit))

print("\n=== 2. 底线：窗口不能比屏幕宽 ===\n")
check("窗口宽度 ≤ 屏幕可见宽度",
      window.frame.width <= screen.width,
      String(format: "%.0f vs %.0f", window.frame.width, screen.width))
check("窗口宽度 ≤ 折行上限 + 余量",
      window.frame.width <= limit + 8 + 0.5,
      String(format: "%.0f vs %.0f", window.frame.width, limit + 8))

let leftShiftFree = screen.width - window.frame.width
print(String(format: "\n  选区左边缘 ≤ %.0f 时不会左移（窗口宽 %.0f）", leftShiftFree, window.frame.width))
print(String(format: "  修复前：选区左边缘 ≤ -17 就会左移 —— 也就是每次都左移"))

print("\n=== 3. 逐行内容（按 y 分行）===\n")
// 分组标签高 10，其余控件高 ≥ 14 —— 用它把标签与控件分开
func isGroupLabel(_ v: NSView) -> Bool { v is NSTextField && abs(v.frame.height - 10) < 0.5 }
let laidOut = toolbar.subviews.filter { v in
    v.frame.height > 1 && !isGroupLabel(v)
}
var rowOf: [Int: [NSView]] = [:]
for v in laidOut {
    let r = Int(((toolbar.frame.height - v.frame.maxY) / rowHeight).rounded(.down))
    rowOf[r, default: []].append(v)
}

var widestRow: CGFloat = 0
for r in rowOf.keys.sorted() {
    let items = rowOf[r]!.sorted { $0.frame.minX < $1.frame.minX }
    let left = items.map(\.frame.minX).min() ?? 0
    let right = items.map(\.frame.maxX).max() ?? 0
    widestRow = max(widestRow, right)
    let names = items.map { v -> String in
        if let b = v as? NSButton { return b.title.isEmpty ? "按钮" : b.title }
        if let p = v as? NSPopUpButton { return "下拉·" + (p.titleOfSelectedItem ?? "") }
        if v is NSSlider { return "滑块" }
        if let t = v as? NSTextField { return "文本·" + t.stringValue }
        return "容器"
    }
    print(String(format: "  行%d  x %.0f…%.0f  (%.0f 宽)  %@", r, left, right, right - left,
                 names.joined(separator: " ")))
    check("行 \(r) 的右边界 ≤ 折行上限", right <= limit + 0.5,
          String(format: "%.0f vs %.0f", right, limit))
}
check("所有行都在工具栏框内", widestRow <= toolbar.frame.width + 0.5,
      String(format: "%.0f vs %.0f", widestRow, toolbar.frame.width))

print("\n=== 4. 控件完整性：折行不能把任何控件弄丢 ===\n")
let labels = toolbar.subviews.filter(isGroupLabel).count
// ⚠️ NSPopUpButton 是 NSButton 的**子类**，直接数 NSButton 会把 3 个下拉也算进去
// （第一版就是这么写的，数出 24 而预期 20 —— 是断言错了，不是代码错了）。
let plainButtons = toolbar.subviews.compactMap { $0 as? NSButton }
    .filter { !($0 is NSPopUpButton) }.count
let popups = toolbar.subviews.compactMap { $0 as? NSPopUpButton }.count
check("分组标签数 = 10（11 组里「帮助」无标签）", labels == 10, "\(labels)")
check("普通按钮 21 个（12 工具 + 撤销/重做/换色/启用/保存/复制/贴图/OCR/帮助）",
      plainButtons == 21, "\(plainButtons)")
check("下拉 3 个（箭头样式 / 线型 / 贴纸）", popups == 3, "\(popups)")
check("每个控件的 y 都在工具栏高度内",
      laidOut.allSatisfy { $0.frame.minY >= -0.5 && $0.frame.maxY <= toolbar.frame.height + 0.5 })

print("\n=== 5. 折行是「按组」的，不会把一组劈成两行 ===\n")
// 逐行检查：每个分组标签必须与它所属组的第一个控件在同一行
let labelViews = toolbar.subviews.filter(isGroupLabel)
var splitGroups = 0
for label in labelViews {
    let labelRow = Int(((toolbar.frame.height - label.frame.maxY) / rowHeight).rounded(.down))
    // 该组第一个控件 = 同一行里 x 最接近标签 x 的控件
    let sameRow = laidOut.filter { v in
        Int(((toolbar.frame.height - v.frame.maxY) / rowHeight).rounded(.down)) == labelRow
    }
    let nearest = sameRow.min { abs($0.frame.minX - label.frame.minX) < abs($1.frame.minX - label.frame.minX) }
    if let nearest = nearest, abs(nearest.frame.minX - label.frame.minX) > 2 {
        splitGroups += 1
    }
}
check("每个分组标签都与它的第一个控件同行同列（组没被劈开）",
      splitGroups == 0, "错位 \(splitGroups) 处")


print("\n=== 通过 \(pass)，失败 \(fail) ===")
exit(fail == 0 ? 0 : 1)
