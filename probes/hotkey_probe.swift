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
// 默认值本身**不再写死在断言里**：算成一个变量再比。
// 原先断言"区域截图 = ⇧⌘A"这种字面值，一改默认值探针就红 —— 而"改默认值"
// 恰恰是它该允许发生的事。这里只钉住"默认值必须满足的性质"。
let regionDisplay = region.displayString
let windowDisplay = windowKey.displayString
check("均可用", region.isUsable && windowKey.isUsable)
check("均不在系统截图黑名单",
      !HotkeyConfig.systemScreenshotCombos.contains(region)
      && !HotkeyConfig.systemScreenshotCombos.contains(windowKey))
check("两者互不冲突", region != windowKey)
check("都含 ⌘ 或 ⌃（命令型修饰键，不参与常规文本输入）",
      region.carbonModifiers & UInt32(cmdKey | controlKey) != 0
      && windowKey.carbonModifiers & UInt32(cmdKey | controlKey) != 0,
      "\(regionDisplay) / \(windowDisplay)")

// ★ 这一条是第四批之后加的真问题：全局热键是会话级独占的，注册后那个组合就
//   不再到达任何前台应用。若默认值落在主流应用的高频菜单键上，等于开箱就静默
//   劫持掉用户常用快捷键 —— 而症状完全不像截图工具干的。
//   ⌘⇧W 在浏览器里是"关闭窗口"，⌘⇧A 在 Firefox 里是"扩展管理"，都曾是我们的默认值。
let highFrequencyMenuCombos: [(String, HotkeyConfig)] = [
    ("⌘⇧W 浏览器「关闭窗口」", mk(kVK_ANSI_W, cmdKey | shiftKey)),
    ("⌘⇧A 部分应用「附加组件」", mk(kVK_ANSI_A, cmdKey | shiftKey)),
    ("⌘⇧S 各应用「另存为」", mk(kVK_ANSI_S, cmdKey | shiftKey)),
    ("⌘⇧T 浏览器「恢复标签页」", mk(kVK_ANSI_T, cmdKey | shiftKey)),
]
for (label, combo) in highFrequencyMenuCombos {
    check("默认值避开 \(label)", region != combo && windowKey != combo)
}

print("\n=== 6. 持久化往返 + 脏数据回退 ===\n")
let suiteName = "com.aisnap.probe.hotkeys"
let store = UserDefaults(suiteName: suiteName)!
let prefs = Preferences(defaults: store)

check("缺省时读到默认（\(regionDisplay)）", prefs.regionCaptureHotkey.displayString == regionDisplay,
      prefs.regionCaptureHotkey.displayString)

let custom = mk(kVK_ANSI_S, cmdKey | optionKey)
prefs.regionCaptureHotkey = custom
check("改键后跨实例读回", Preferences(defaults: store).regionCaptureHotkey == custom,
      Preferences(defaults: store).regionCaptureHotkey.displayString)

store.set("garbage", forKey: "hotkeyRegion")
check("格式错误 → 回默认", Preferences(defaults: store).regionCaptureHotkey.displayString == regionDisplay,
      Preferences(defaults: store).regionCaptureHotkey.displayString)

store.set("\(kVK_ANSI_A):0", forKey: "hotkeyRegion")
check("已存值无修饰键 → 回默认", Preferences(defaults: store).regionCaptureHotkey.displayString == regionDisplay,
      Preferences(defaults: store).regionCaptureHotkey.displayString)

store.set("\(kVK_ANSI_A):\(shiftKey)", forKey: "hotkeyRegion")
check("已存值仅 ⇧ → 回默认（不注册会抢打字的键）",
      Preferences(defaults: store).regionCaptureHotkey.displayString == regionDisplay,
      Preferences(defaults: store).regionCaptureHotkey.displayString)

prefs.regionCaptureHotkey = custom
check("resetToDefaults 后回默认",
      { prefs.resetToDefaults()
        return Preferences(defaults: store).regionCaptureHotkey.displayString == regionDisplay }())

// 清理测试域。
    //
    // ⚠️ 只调 removePersistentDomain 是**不够**的：它清的是当前进程视角的域，
    // 磁盘上的 ~/Library/Preferences/<suite>.plist 会留下。
    // 早先 suite 名还用了 UUID()，于是探针每跑一次就多一个 plist ——
    // 实测在用户机器上累积了 24 个 com.aisnap.*test.*.plist。
    // 现在：固定 suite 名（不会累积）+ 显式删文件（不会残留）。
    func cleanupTestDomain() {
        // 顺序很重要：**先同步**把待写数据刷到磁盘，再删域、再删文件。
        // 反过来的话，cfprefsd 会在我们删完之后才把文件写出来 ——
        // 实测「删了但文件还在」，就是踩了这个异步落盘。
        CFPreferencesAppSynchronize(suiteName as CFString)
        store.removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: url)
    }
    cleanupTestDomain()

print("\n=== 结果 ===")
if failures == 0 { print("全部通过") } else { print("\(failures) 项失败"); exit(1) }
