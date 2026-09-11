// HotkeyConfig 的真实行为测试（链接真实源码，不是复刻）
import Cocoa
import Carbon.HIToolbox

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !ok { failures += 1 }
}

let mk = { (k: Int, m: Int) in HotkeyConfig(keyCode: UInt32(k), carbonModifiers: UInt32(m)) }

print("=== 1. 展示字符串：修饰键顺序按 Apple HIG 的 ⌃⌥⇧⌘ ===\n")
print("  （所以 ⌘⇧A 应渲染为 ⇧⌘A —— 对照访达「新建文件夹」显示为 ⇧⌘N）\n")
check("⌘⇧A → ⇧⌘A", mk(kVK_ANSI_A, cmdKey | shiftKey).displayString == "⇧⌘A",
      mk(kVK_ANSI_A, cmdKey | shiftKey).displayString)
check("⌘⇧W → ⇧⌘W", mk(kVK_ANSI_W, cmdKey | shiftKey).displayString == "⇧⌘W",
      mk(kVK_ANSI_W, cmdKey | shiftKey).displayString)
check("⌘A → ⌘A", mk(kVK_ANSI_A, cmdKey).displayString == "⌘A",
      mk(kVK_ANSI_A, cmdKey).displayString)
check("四键全按 ⌃⌥⇧⌘",
      mk(kVK_ANSI_1, cmdKey | shiftKey | optionKey | controlKey).displayString == "⌃⌥⇧⌘1",
      mk(kVK_ANSI_1, cmdKey | shiftKey | optionKey | controlKey).displayString)
check("空格键有名字", mk(kVK_Space, cmdKey).displayString == "⌘空格",
      mk(kVK_Space, cmdKey).displayString)
check("未覆盖的键码 → ?", mk(kVK_F1, cmdKey).displayString == "⌘?")

print("\n=== 2. isUsable：必须含 ⌘ 或 ⌃ ===\n")
print("  （只用 ⇧ / ⌥ 会抢掉系统范围内的正常打字，必须拒绝）\n")
check("⌘⇧A 可用", mk(kVK_ANSI_A, cmdKey | shiftKey).isUsable)
check("⌃⇧A 可用", mk(kVK_ANSI_A, controlKey | shiftKey).isUsable)
check("⌘⌥⇧A 可用", mk(kVK_ANSI_A, cmdKey | optionKey | shiftKey).isUsable)
check("单独 A（无修饰键）不可用", mk(kVK_ANSI_A, 0).isUsable == false)
check("单独 ⇧ 不可用（会抢大写 A）", mk(kVK_ANSI_A, shiftKey).isUsable == false)
check("单独 ⌥ 不可用（会抢特殊字符输入）", mk(kVK_ANSI_A, optionKey).isUsable == false)
check("⇧⌥ 也不可用（仍无 ⌘/⌃）", mk(kVK_ANSI_A, shiftKey | optionKey).isUsable == false)
check("未覆盖键码不可用", mk(kVK_F1, cmdKey).isUsable == false)

print("\n=== 3. NSEvent 修饰键 → Carbon 位掩码 ===\n")
check("⌘⇧", HotkeyConfig.carbonModifiers(from: [.command, .shift]) == UInt32(cmdKey | shiftKey),
      "\(HotkeyConfig.carbonModifiers(from: [.command, .shift]))")
check("⌘⌥⌃", HotkeyConfig.carbonModifiers(from: [.command, .option, .control])
      == UInt32(cmdKey | optionKey | controlKey),
      "\(HotkeyConfig.carbonModifiers(from: [.command, .option, .control]))")
check("无修饰键 → 0", HotkeyConfig.carbonModifiers(from: []) == 0)
check("大写锁定被忽略", HotkeyConfig.carbonModifiers(from: [.capsLock]) == 0,
      "\(HotkeyConfig.carbonModifiers(from: [.capsLock]))")
check("功能键标志被忽略", HotkeyConfig.carbonModifiers(from: [.function]) == 0)

print("\n=== 4. 系统截图快捷键黑名单 ===\n")
for digit in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6] {
    let combo = mk(digit, cmdKey | shiftKey)
    check("\(combo.displayString) 在黑名单内",
          HotkeyConfig.systemScreenshotCombos.contains(combo))
}
check("⇧⌘A 不在黑名单内",
      HotkeyConfig.systemScreenshotCombos.contains(mk(kVK_ANSI_A, cmdKey | shiftKey)) == false)

print("\n=== 5. 默认快捷键 ===\n")
let region = Preferences.Defaults.regionCaptureHotkey
let windowKey = Preferences.Defaults.windowCaptureHotkey
check("区域截图 = ⇧⌘A", region.displayString == "⇧⌘A", region.displayString)
check("窗口截图 = ⇧⌘W", windowKey.displayString == "⇧⌘W", windowKey.displayString)
check("均可用", region.isUsable && windowKey.isUsable)
check("均不在系统截图黑名单",
      !HotkeyConfig.systemScreenshotCombos.contains(region)
      && !HotkeyConfig.systemScreenshotCombos.contains(windowKey))
check("两者互不冲突", region != windowKey)

print("\n=== 6. 持久化往返 + 脏数据回退 ===\n")
let suite = "com.aisnap.hotkeytest.\(UUID().uuidString)"
let store = UserDefaults(suiteName: suite)!
let prefs = Preferences(defaults: store)

check("缺省时读到默认 ⇧⌘A", prefs.regionCaptureHotkey.displayString == "⇧⌘A",
      prefs.regionCaptureHotkey.displayString)

let custom = mk(kVK_ANSI_S, cmdKey | optionKey)
prefs.regionCaptureHotkey = custom
check("改键后跨实例读回", Preferences(defaults: store).regionCaptureHotkey == custom,
      Preferences(defaults: store).regionCaptureHotkey.displayString)

store.set("garbage", forKey: "hotkeyRegion")
check("格式错误 → 回默认", Preferences(defaults: store).regionCaptureHotkey.displayString == "⇧⌘A",
      Preferences(defaults: store).regionCaptureHotkey.displayString)

store.set("\(kVK_ANSI_A):0", forKey: "hotkeyRegion")
check("已存值无修饰键 → 回默认", Preferences(defaults: store).regionCaptureHotkey.displayString == "⇧⌘A",
      Preferences(defaults: store).regionCaptureHotkey.displayString)

store.set("\(kVK_ANSI_A):\(shiftKey)", forKey: "hotkeyRegion")
check("已存值仅 ⇧ → 回默认（不注册会抢打字的键）",
      Preferences(defaults: store).regionCaptureHotkey.displayString == "⇧⌘A",
      Preferences(defaults: store).regionCaptureHotkey.displayString)

prefs.regionCaptureHotkey = custom
check("resetToDefaults 后回默认",
      { prefs.resetToDefaults()
        return Preferences(defaults: store).regionCaptureHotkey.displayString == "⇧⌘A" }())

store.removePersistentDomain(forName: suite)

print("\n=== 结果 ===")
if failures == 0 { print("全部通过") } else { print("\(failures) 项失败"); exit(1) }
