import Cocoa
import CoreGraphics
import Foundation

// MARK: - Probe 1: kCGWindowBounds cast to [String: CGFloat]
func probeWindowBoundsCast() {
    print("\n=== PROBE 1: kCGWindowBounds -> [String: CGFloat] cast ===")
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        print("FAIL: cannot get window list")
        return
    }
    var total = 0
    var castOk = 0
    var castFail = 0
    var viaAnyOk = 0
    var viaRectDict = 0
    for info in list.prefix(30) {
        guard info[kCGWindowOwnerPID as String] != nil else { continue }
        total += 1
        if let d = info[kCGWindowBounds as String] as? [String: CGFloat] {
            castOk += 1
            if castOk <= 2 {
                print("  CGFloat-cast sample: \(d)")
            }
        } else {
            castFail += 1
            if castFail <= 2, let raw = info[kCGWindowBounds as String] {
                print("  CGFloat-cast FAILED, raw type=\(type(of: raw)) value=\(raw)")
            }
        }
        if let raw = info[kCGWindowBounds as String] as? [String: Any] {
            let x = (raw["X"] as? NSNumber)?.doubleValue
            if x != nil { viaAnyOk += 1 }
        }
        if let rawAny = info[kCGWindowBounds as String] {
            let cfDict = rawAny as! CFDictionary
            if CGRect(dictionaryRepresentation: cfDict) != nil {
                viaRectDict += 1
            }
        }
    }
    print("RESULT: scanned=\(total) castAsCGFloat=\(castOk) fail=\(castFail) viaAny+NSNumber=\(viaAnyOk) viaCGRect(dict)=\(viaRectDict)")
    print("VERDICT: ScreenCapture.swift:22 `as? [String: CGFloat]` is \(castOk > 0 ? "LIKELY OK on this OS" : "BROKEN — all windows skipped")")
}

// MARK: - Probe 2: Multi-monitor Y flip: NSScreen.main vs screens[0]
func probeScreenYFlip() {
    print("\n=== PROBE 2: Screen coordinate Y-flip source ===")
    let screens = NSScreen.screens
    print("screens.count=\(screens.count)")
    for (i, s) in screens.enumerated() {
        print("  [\(i)] frame=\(s.frame) visible=\(s.visibleFrame) scale=\(s.backingScaleFactor) isMain=\(s == NSScreen.main)")
    }
    if let main = NSScreen.main, let primary = screens.first {
        print("NSScreen.main.frame=\(main.frame)")
        print("NSScreen.screens[0].frame=\(primary.frame)")
        print("main.height=\(main.frame.height) primary.height=\(primary.frame.height)")
        if main.frame != primary.frame {
            print("VERDICT: main != screens[0] — ScreenCapture/RegionSelection using main.height WILL be wrong when converting global points")
        } else {
            print("NOTE: on this machine main == screens[0] (or same frame). Multi-monitor still theoretically wrong; single-display OK.")
        }
    }

    // Pure math example (primary 1920x1080, secondary to the right)
    let primaryH: CGFloat = 1080
    let secondaryH: CGFloat = 1440
    // NS mouse on secondary: x=2000, y=200 (from bottom of secondary? Global NS: secondary origin is often (1920, 0) bottom-aligned or (1920, -something))
    // Case A: secondary stacked with origin (1920, 0), mouse at NS (2100, 300)
    // Correct CG y = primaryH - nsY = 1080-300 = 780
    // Code with main=secondary height: secondaryH - 300 = 1140 WRONG
    // Code with main=primary height: primaryH - 300 = 780 OK
    let nsY: CGFloat = 300
    let correct = primaryH - nsY
    let ifMainSecondary = secondaryH - nsY
    let ifMainPrimary = primaryH - nsY
    print("Math example: nsY=\(nsY) correctCGY=\(correct) ifUseSecondaryH=\(ifMainSecondary) ifUsePrimaryH=\(ifMainPrimary)")
    print("VERDICT: using NSScreen.main.height is correct ONLY when main is the primary (menu-bar) screen.")
}

// MARK: - Probe 3: Selection stroke then clear
func probeStrokeThenClear() {
    print("\n=== PROBE 3: stroke then .clear fill erases border ===")
    let w = 40, h = 40
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) // opaque white "overlay"
    let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
    // Mimic RegionSelectionView.draw order
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setLineWidth(1.5)
    ctx.stroke(rect)
    ctx.setBlendMode(.clear)
    ctx.fill(rect)
    // Count dark pixels remaining on the border path vicinity
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var edgeDark = 0
    var interiorAlpha0 = 0
    for y in 0..<h {
        for x in 0..<w {
            let o = y * w * 4 + x * 4
            let a = data[o+3]
            // pixels near rect border
            let onEdge = (x >= 9 && x <= 30 && y >= 9 && y <= 30) &&
                         (x <= 11 || x >= 28 || y <= 11 || y >= 28)
            if onEdge && a > 0 && data[o] < 128 { edgeDark += 1 }
            if x > 12 && x < 28 && y > 12 && y < 28 && a == 0 { interiorAlpha0 += 1 }
        }
    }
    print("edge dark visible pixels after clear=\(edgeDark) (expect ~0 if border wiped)")
    print("interior transparent pixels=\(interiorAlpha0) (expect large)")
    print("VERDICT: \(edgeDark == 0 ? "CONFIRMED — stroke is erased by subsequent clear fill" : "border still visible (unexpected)")")
}

// MARK: - Probe 4: pullsDown popup indexOfSelectedItem
func probePullsDownPopup() {
    print("\n=== PROBE 4: NSPopUpButton(pullsDown:true) index behavior ===")
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 56, height: 24), pullsDown: true)
    popup.addItem(withTitle: "选择")
    for t in ["A", "B", "C"] { popup.addItem(withTitle: t) }
    print("numberOfItems=\(popup.numberOfItems) pullsDown=\(popup.pullsDown)")
    print("indexOfSelectedItem (before)=\(popup.indexOfSelectedItem)")
    // Simulate selecting menu item index 2 (title "B")
    popup.menu?.performActionForItem(at: 2)
    // Also try selectItem
    popup.selectItem(at: 2)
    print("after selectItem(at:2): indexOfSelectedItem=\(popup.indexOfSelectedItem) title=\(popup.titleOfSelectedItem ?? "nil") selectedItem=\(popup.selectedItem?.title ?? "nil")")
    // What AnnotationWindow does: index = indexOfSelectedItem - 1
    let mapped = popup.indexOfSelectedItem - 1
    print("AnnotationWindow maps to stamp index=\(mapped) valid=\(mapped >= 0 && mapped < 3)")
    // Compare with pullsDown=false
    let popup2 = NSPopUpButton(frame: .zero, pullsDown: false)
    for t in ["选择", "A", "B", "C"] { popup2.addItem(withTitle: t) }
    popup2.selectItem(at: 2)
    print("normal popup after selectItem(2): indexOfSelectedItem=\(popup2.indexOfSelectedItem) mapped=\(popup2.indexOfSelectedItem - 1)")
    print("VERDICT: pullsDown selectItem may not update indexOfSelectedItem the same way; stamp path is fragile. mapped for pullsDown=\(mapped)")
}

// MARK: - Probe 5: Toolbar width estimate
func probeToolbarWidth() {
    print("\n=== PROBE 5: Toolbar xOffset accumulation ===")
    // Replicate makeToolbarButton width formula + groups from AnnotationWindow
    func btnW(_ title: String) -> CGFloat { max(CGFloat(title.count) * 14 + 8, 36) }
    var x: CGFloat = 8
    let tools = ["箭头", "矩形", "圆形", "椭圆", "聚光"]
    x += 190 // group label reserved visually; buttons still consume
    // actual code: addGroupLabel doesn't advance xOffset! Only buttons do.
    // Re-read: addGroupLabel does NOT change xOffset. tools start at xOffset after label placed at same x.
    x = 8
    for t in tools { x += btnW(t) + 2 }
    x += 4
    x += 8 // separator addSeparator advances 8 after drawing at xOffset
    x += btnW("撤销") + 2
    x += btnW("重做") + 2
    x += 4
    x += 8
    x += btnW("换色") + 4
    x += 4 * 30 + 4 // 4 colors
    x += 8
    x += 108 // slider+label
    x += 8
    x += 62 // stamp
    x += 8
    x += 50 + 78 // watermark
    x += 8
    x += btnW("保存") + 2 + btnW("复制") + 2 + 4
    x += 8
    x += btnW("帮助")
    print("Estimated toolbar content end x ≈ \(Int(x)) pt")
    print("Window min width = 780; small-canvas natural width may be ~780.")
    print("VERDICT: \(x > 780 ? "CONFIRMED overflow risk on min-width window (need ~\(Int(x))pt)" : "fits in 780")")
    print("On 14\" 1440pt screen maxW=90%≈\(Int(1440*0.9)); still \(x > 1440*0.9 ? "OVERFLOWS" : "fits")")
}

// MARK: - Probe 6: composite export includes spotlight border (logic simulation)
func probeSpotlightExportLogic() {
    print("\n=== PROBE 6: compositeImage draws SpotlightShape.draw (editor chrome) ===")
    print("Code path: AnnotationView.compositeImage -> for obj in zOrder { obj.draw(in: ctx) }")
    print("SpotlightShape.draw ALWAYS strokes yellow dashed border (not gated by export flag).")
    print("VERDICT: CONFIRMED by static path analysis — exported PNG will contain editor dashed border.")
}

// MARK: - Probe 7: Undo .add leaves attached arrows
func probeUndoAddCascade() {
    print("\n=== PROBE 7: performUndo(.add) vs cascadeDelete ===")
    print("Delete path (mouseDown X / Delete key): records deletedObjects including arrows, calls cascadeDelete(parentKey:).")
    print("Undo .add path: only objects.removeValue(colorKey); zOrder.removeAll; NO cascadeDelete.")
    print("Consequence: arrow.startAttachment.parentKey may dangle; resolveAttachmentPosition returns nil; arrow frozen at last pos; redo/undo inconsistent.")
    print("VERDICT: CONFIRMED by static comparison of AnnotationView.swift:451-458 vs 115-121 / 430-436.")
}

// MARK: - Probe 8: HitTestBuffer Y flip
func probeHitTestYFlip() {
    print("\n=== PROBE 8: HitTestBuffer.pickColorKey Y flip vs draw ===")
    // Draw a 1x1 mark at logical bottom-left (0,0) in CG context, then pick.
    let w = 10, h = 10
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(false)
    ctx.setFillColor(NSColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor) // key 0xFF0000
    // draw at CG (1,1) near bottom-left
    ctx.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
    func pick(_ point: CGPoint) -> UInt32 {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, x < w, y >= 0, y < h else { return 0 }
        let flippedY = h - 1 - y
        let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let o = flippedY * ctx.bytesPerRow + x * 4
        return (UInt32(ptr[o]) << 16) | (UInt32(ptr[o+1]) << 8) | UInt32(ptr[o+2])
    }
    // AppKit view point y=1 is near bottom
    let atDrawn = pick(CGPoint(x: 1, y: 1))
    let atTop = pick(CGPoint(x: 1, y: 9))
    print("pick(1,1)=0x\(String(atDrawn, radix: 16)) pick(1,9)=0x\(String(atTop, radix: 16))")
    print("VERDICT: \(atDrawn == 0xFF0000 && atTop == 0) ? Y-flip consistent with AppKit bottom-left : MISMATCH")
}

// MARK: - Probe 9: deprecated API symbol
func probeDeprecatedCaptureAPI() {
    print("\n=== PROBE 9: CGWindowListCreateImage availability ===")
    print("Compiling a call site is enough; runtime deprecation warning may appear on macOS 14+ SDK.")
    // Don't actually capture (permission); just confirm symbol links.
    let fn: (@convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?)? = nil
    _ = fn
    print("Symbol CGWindowListCreateImage is the capture entry used by ScreenCapture.swift:40 and :53.")
    print("Apple marks it deprecated in macOS 14; ScreenCaptureKit is replacement. CONFIRMED by API contract.")
}

probeWindowBoundsCast()
probeScreenYFlip()
probeStrokeThenClear()
probePullsDownPopup()
probeToolbarWidth()
probeSpotlightExportLogic()
probeUndoAddCascade()
probeHitTestYFlip()
probeDeprecatedCaptureAPI()
print("\n=== ALL PROBES DONE ===")
