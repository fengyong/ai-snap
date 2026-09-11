// Preferences 的真实行为测试
//
// 注意：这个探针链接的是**真实的** Sources/Models.swift + Sources/Preferences.swift，
// 不是复刻逻辑 —— 因为 Preferences 是纯逻辑（UserDefaults 读写 + 颜色转换），
// 可以脱离 GUI 直接测。这比「肉眼看一遍代码」可靠得多。
import Cocoa

let suiteName = "com.aisnap.prefstest.\(UUID().uuidString)"
guard let store = UserDefaults(suiteName: suiteName) else {
    print("无法创建测试用 UserDefaults suite"); exit(1)
}
let prefs = Preferences(defaults: store)

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("  \(condition ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !condition { failures += 1 }
}

print("=== 1. 全新存储：应返回缺省值 ===\n")
check("lineWidth = 15", prefs.lineWidth == 15, "\(prefs.lineWidth)")
check("lineStyle = .solid", prefs.lineStyle == .solid, "\(prefs.lineStyle)")
check("color = red", Preferences.hexString(from: prefs.color) == "#FF0000",
      Preferences.hexString(from: prefs.color))
check("arrowStyle = 首个预设", prefs.arrowStyle == ArrowStyle.allPresets[0])
check("paletteIndex = 0", prefs.paletteIndex == 0, "\(prefs.paletteIndex)")
check("lastToolTag = 0", prefs.lastToolTag == 0, "\(prefs.lastToolTag)")
check("watermarkEnabled = false", prefs.watermarkEnabled == false)
check("watermarkText = AISnap", prefs.watermarkText == "AISnap", prefs.watermarkText)

print("\n=== 2. 写入后读回（跨实例，模拟重启）===\n")
prefs.lineWidth = 22.5
prefs.lineStyle = .dotted
prefs.color = NSColor(srgbRed: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0, alpha: 1)
prefs.arrowStyle = ArrowStyle.allPresets[3]
prefs.paletteIndex = 2
prefs.lastToolTag = 4
prefs.watermarkEnabled = true
prefs.watermarkText = "机密"

let reopened = Preferences(defaults: store)     // 新的实例，读同一份存储
check("lineWidth = 22.5", reopened.lineWidth == 22.5, "\(reopened.lineWidth)")
check("lineStyle = .dotted", reopened.lineStyle == .dotted, "\(reopened.lineStyle)")
check("color = #123456", Preferences.hexString(from: reopened.color) == "#123456",
      Preferences.hexString(from: reopened.color))
check("arrowStyle = 第 4 个预设", reopened.arrowStyle == ArrowStyle.allPresets[3])
check("paletteIndex = 2", reopened.paletteIndex == 2, "\(reopened.paletteIndex)")
check("lastToolTag = 4", reopened.lastToolTag == 4, "\(reopened.lastToolTag)")
check("watermarkEnabled = true", reopened.watermarkEnabled == true)
check("watermarkText = 机密", reopened.watermarkText == "机密", reopened.watermarkText)

print("\n=== 3. 水印配置整体读出 ===\n")
let cfg = reopened.watermarkConfig
check("text 透传", cfg.text == "机密", cfg.text)
check("enabled 透传", cfg.enabled == true)
check("未暴露的字段保持代码默认（fontSize=14）", cfg.fontSize == 14, "\(cfg.fontSize)")
check("未暴露的字段保持代码默认（tiled=true）", cfg.tiled == true)

print("\n=== 4. 脏数据：不应崩溃、应回退到缺省 ===\n")
store.set("bogus-style", forKey: "lineStyle")
store.set(999, forKey: "paletteIndex")
store.set(999, forKey: "arrowStyleIndex")
store.set("not-a-number", forKey: "lineWidth")
store.set("not-a-color", forKey: "colorHex")
store.set("not-a-bool", forKey: "watermarkEnabled")

let dirty = Preferences(defaults: store)
check("非法 lineStyle → .solid", dirty.lineStyle == .solid, "\(dirty.lineStyle)")
check("越界 paletteIndex → 0", dirty.paletteIndex == 0, "\(dirty.paletteIndex)")
check("越界 arrowStyleIndex → 首个预设", dirty.arrowStyle == ArrowStyle.allPresets[0])
check("类型错误 lineWidth → 15", dirty.lineWidth == 15, "\(dirty.lineWidth)")
check("非法 colorHex → red", Preferences.hexString(from: dirty.color) == "#FF0000",
      Preferences.hexString(from: dirty.color))
check("类型错误 watermarkEnabled → false", dirty.watermarkEnabled == false)

print("\n=== 5. 颜色互转（含非 RGB 色彩空间，这是最容易崩的地方）===\n")
let gray = NSColor(white: 0.5, alpha: 1)                  // 灰度空间
let hexGray = Preferences.hexString(from: gray)
check("灰度色不崩且转出合法值", hexGray.count == 7 && hexGray.hasPrefix("#"), hexGray)
check("灰度 0.5 → #808080", hexGray == "#808080", hexGray)

let named = NSColor.systemBlue                             // 命名色（可能是 catalog 空间）
check("命名色不崩", Preferences.hexString(from: named).count == 7)

let roundTrip = Preferences.color(fromHex: Preferences.hexString(from: named))
check("命名色往返后仍接近原色",
      roundTrip != nil && abs(roundTrip!.blueComponent - 1.0) < 0.02,
      Preferences.hexString(from: roundTrip ?? .black))

check("非法 hex 返回 nil", Preferences.color(fromHex: "#GGGGGG") == nil)
check("长度错误返回 nil", Preferences.color(fromHex: "#FFF") == nil)

print("\n=== 6. resetToDefaults ===\n")
let before = Preferences(defaults: store)
check("重置前是脏数据状态", before.lineWidth == 15 && before.watermarkText == "机密")
before.resetToDefaults()
let after = Preferences(defaults: store)
check("lineWidth 回缺省", after.lineWidth == 15, "\(after.lineWidth)")
check("lineStyle 回缺省", after.lineStyle == .solid, "\(after.lineStyle)")
check("color 回缺省", Preferences.hexString(from: after.color) == "#FF0000")
check("watermarkText 回缺省", after.watermarkText == "AISnap", after.watermarkText)
check("paletteIndex 回缺省", after.paletteIndex == 0, "\(after.paletteIndex)")
check("lastToolTag 回缺省", after.lastToolTag == 0, "\(after.lastToolTag)")

store.removePersistentDomain(forName: suiteName)

print("\n=== 结果 ===")
if failures == 0 {
    print("全部通过")
} else {
    print("\(failures) 项失败")
    exit(1)
}
