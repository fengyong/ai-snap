import Cocoa
import CoreGraphics

print("=== PROBE 14: PID / WindowID cast types from CGWindowList ===")
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    print("no list"); exit(1)
}
var pidOk = 0, pidFail = 0, idOk = 0, idFail = 0
for info in list.prefix(40) {
    let pidRaw = info[kCGWindowOwnerPID as String]
    let idRaw = info[kCGWindowNumber as String]
    if pidRaw is Int32 { pidOk += 1 }
    else if pidRaw != nil {
        pidFail += 1
        if pidFail <= 2 { print("  PID raw type=\(type(of: pidRaw!)) value=\(pidRaw!)") }
    }
    if idRaw is CGWindowID { idOk += 1 }
    else if idRaw != nil {
        idFail += 1
        if idFail <= 2 { print("  WID raw type=\(type(of: idRaw!)) value=\(idRaw!)") }
    }
}
print("PID as Int32 ok=\(pidOk) fail=\(pidFail); WindowID as CGWindowID ok=\(idOk) fail=\(idFail)")

print("\n=== PROBE 15: Window hit-test Y flip with real multi-monitor layout ===")
let primary = NSScreen.screens[0]
print("primary=\(primary.frame) main=\(NSScreen.main!.frame)")
// Pick a few real windows and test both formulas
var tested = 0
for info in list {
    guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
          let onscreen = info[kCGWindowIsOnscreen as String] as? Bool, onscreen,
          let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
          boundsDict["Width"]! > 50, boundsDict["Height"]! > 50 else { continue }
    let bounds = CGRect(x: boundsDict["X"]!, y: boundsDict["Y"]!,
                        width: boundsDict["Width"]!, height: boundsDict["Height"]!)
    // Use window center in CG space, convert back to NS to simulate mouse at window center
    let cgCenter = CGPoint(x: bounds.midX, y: bounds.midY)
    // Inverse of ns→cg: nsY = primary.maxY - cgY, nsX = cgX
    let nsY = primary.frame.maxY - cgCenter.y
    let nsMouse = CGPoint(x: cgCenter.x, y: nsY)
    let flipMain = (NSScreen.main?.frame.height ?? 0) - nsMouse.y
    let flipPrimary = primary.frame.height - nsMouse.y
    let hitMain = bounds.contains(CGPoint(x: nsMouse.x, y: flipMain))
    let hitPrimary = bounds.contains(CGPoint(x: nsMouse.x, y: flipPrimary))
    print("  window bounds=\(bounds) nsMouse=\(nsMouse)")
    print("    flipMainH=\(flipMain) flipPrimaryH=\(flipPrimary) hitWithMain=\(hitMain) hitWithPrimary=\(hitPrimary)")
    tested += 1
    if tested >= 5 { break }
}
print("On this machine main==primary so both flips match. If NSScreen.main becomes a secondary screen, main.height≠primary.height and hits break.")

print("\n=== PROBE 16: secondary-screen region capture Y error (simulated) ===")
// Suppose selection on secondary screen [2] frame (-2048, 288, 2048, 1152)
// View-local rect origin (100, 50) size 200x100 — NSView y-up, origin bottom-left of that screen
let sec = NSScreen.screens[2]
let local = CGRect(x: 100, y: 50, width: 200, height: 100)
// Global NS
let globalNS = CGRect(x: sec.frame.minX + local.minX, y: sec.frame.minY + local.minY,
                      width: local.width, height: local.height)
// Correct CG (top-left primary origin)
let correctCG = CGRect(x: globalNS.minX, y: primary.frame.maxY - globalNS.maxY,
                       width: globalNS.width, height: globalNS.height)
// Code's formula if window is on secondary (uses main.screenFrame = sec.frame if main were secondary)
let codeCG = CGRect(x: local.minX,  // also ignores screen origin! uses view x directly
                    y: sec.frame.height - local.minY - local.height,
                    width: local.width, height: local.height)
print("globalNS=\(globalNS)")
print("correctCG=\(correctCG)")
print("codeCG   =\(codeCG)  // even worse: x uses view-local not global")
print("VERDICT: region capture rect is wrong unless selection screen is primary AND its frame origin is (0,0).")

print("\n=== PROBE 17: activation policy / LSUIElement ===")
print("Info.plist LSUIElement=true; code sets accessory at launch then regular on AnnotationWindow init; never reverts on close.")
print("Manual probe: open annotation window, close it, check Dock icon presence.")

print("\n=== PROBE 18: undo .add cascade reachability (LIFO analysis) ===")
print("""
Scenario A (normal): add rect [U:addR], add arrow [U:addR, addA].
  Undo pops addA first → arrow gone. Undo addR → no live child. cascade not needed.
Scenario B: add rect, add arrow, delete rect via X.
  Delete records [rect, arrows] and cascadeDeletes. Undo restores both.
  Redo deletes both. OK.
Scenario C: add rect, add arrow, undo addA (arrow gone), move rect, undo move, undo addR.
  No live child. OK.
Conclusion: under current LIFO undo, performUndo(.add) without cascade is LATENT,
not a user-reachable bug. Downgrade severity.
""")

print("\n=== PROBE 19: Spotlight perimeter attachment resolve ===")
print("detectAttachment may create .perimeter for SpotlightShape; computePerimeterParameter returns 0; resolveAttachmentPosition has no Spotlight case → nil. Arrow endpoint freezes. snapPoint attach still works.")
print("Refine: only perimeter-anchored arrows on spotlight are broken, not all spotlight attachments.")
