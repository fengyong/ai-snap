import Cocoa

print("=== PROBE 3b: stroke then clear — outer half remains? ===")
let w = 40, h = 40
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(NSColor.white.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
ctx.setStrokeColor(NSColor.black.cgColor)
ctx.setLineWidth(1.5)
ctx.stroke(rect)
// Sample alpha along the left edge before clear
func alphaAt(_ x: Int, _ y: Int) -> UInt8 {
    let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return ptr[y * w * 4 + x * 4 + 3]
}
func rgbAt(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let o = y * w * 4 + x * 4
    return (ptr[o], ptr[o+1], ptr[o+2])
}
print("BEFORE clear, row y=20 x=8..12 RGB:", (8...12).map { rgbAt($0, 20) })
ctx.setBlendMode(.clear)
ctx.fill(rect)
print("AFTER clear,  row y=20 x=8..12 RGB:", (8...12).map { rgbAt($0, 20) })
print("AFTER clear,  col x=20 y=8..12 RGB:", (8...12).map { rgbAt(20, $0) })
// Outer strip x=9 (outside fill, inside stroke half) vs x=11 (inside fill)
print("x=9 (outer half of stroke, outside rect):", rgbAt(9, 20))
print("x=10 (on path):", rgbAt(10, 20))
print("x=11 (inner half, inside rect):", rgbAt(11, 20))
print("VERDICT: clear fill only affects pixels inside rect; outer half of 1.5pt stroke survives. Border becomes ~half-width / dashed-looking, not fully gone.")

print("\n=== PROBE 4b: pullsDown menu action → indexOfSelectedItem ===")
final class Target: NSObject {
    var receivedIndex: Int = -999
    var receivedTitle: String = ""
    @objc func onStamp(_ sender: NSPopUpButton) {
        receivedIndex = sender.indexOfSelectedItem
        receivedTitle = sender.titleOfSelectedItem ?? "nil"
        print("  ACTION fired: indexOfSelectedItem=\(sender.indexOfSelectedItem) title=\(sender.titleOfSelectedItem ?? "nil") menu.items=\(sender.menu?.items.map { $0.title } ?? [])")
    }
}
let target = Target()
let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 56, height: 24), pullsDown: true)
popup.addItem(withTitle: "选择")
popup.addItem(withTitle: "A")
popup.addItem(withTitle: "B")
popup.addItem(withTitle: "C")
popup.target = target
popup.action = #selector(Target.onStamp(_:))
print("pullsDown menu item titles:", popup.menu?.items.map { $0.title } ?? [])
print("item0 isEnabled=\(popup.itemArray[0].isEnabled) title=\(popup.itemArray[0].title)")
// Simulate user clicking menu item "B" (popup index 2)
if let item = popup.itemArray.first(where: { $0.title == "B" }) {
    _ = popup.menu?.performActionForItem(at: popup.index(of: item))
    // Also send action via NSApp in case performActionForItem is async
    if let action = popup.action, let t = popup.target {
        _ = t.perform(action, with: popup)
    }
}
print("direct perform path receivedIndex=\(target.receivedIndex)")
// Documented AppKit: for pulls-down, first item is title and is NOT in the pull-down list
print("VERDICT note: AnnotationWindow uses index-1; if action sees -1 or 0, stamp never applies. Real click path may differ from selectItem.")

print("\n=== PROBE 11: RegionSelection multi-screen coverage ===")
for (i, s) in NSScreen.screens.enumerated() {
    print("  screen[\(i)] frame=\(s.frame) coveredBySelectionUI=\(s == NSScreen.main)")
}
print("Other screens get dark overlay windows but NO drag-selection view.")
print("finishSelection Y uses NSScreen.main.frame.height only — wrong for CG global if main != primary or selection on non-primary.")

print("\n=== PROBE 12: toolbar exact recount from source formula ===")
func btnW(_ title: String) -> CGFloat { max(CGFloat(title.count) * 14 + 8, 36) }
var x: CGFloat = 8
for t in ["箭头", "矩形", "圆形", "椭圆", "聚光"] { x += btnW(t) + 2 }
x += 4; x += 8 // sep
x += btnW("撤销") + 2 + btnW("重做") + 2 + 4; x += 8
x += btnW("换色") + 4 + 4*30 + 4; x += 8
x += 108; x += 8
x += 62; x += 8
x += 50 + 78; x += 8
x += btnW("保存") + 2 + btnW("复制") + 2 + 4; x += 8
x += btnW("帮助")
print("toolbar end x=\(x); window min 780; overflow=\(max(0, x - 780))pt")

print("\n=== PROBE 13: CGWindowListCreateImage deprecation compile-time ===")
// Availability attributes are compile-time; print macOS version
let v = ProcessInfo.processInfo.operatingSystemVersion
print("running macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
print("API deprecated since macOS 14 — still present; will warn on new SDKs.")
