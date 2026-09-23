// HotkeyIgnorePolicy 匹配规则 + 新增偏好项（忽略列表 / 托盘按键动作）回归测试
//
// 链接真实源码：Models.swift + Preferences.swift + HotkeyManager.swift。
// 这几处都是纯逻辑（不依赖真实窗口 / Carbon 注册），可离屏直测。
import Cocoa

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("  \(condition ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    if !condition { failures += 1 }
}

// MARK: - 1. HotkeyIgnorePolicy 匹配规则

print("=== 1. 空输入 ===\n")
check("空规则 → 不忽略", HotkeyIgnorePolicy.isIgnored(bundleID: "com.a.b", rules: []) == false)
check("nil bundleID → 不忽略", HotkeyIgnorePolicy.isIgnored(bundleID: nil, rules: ["com.a.b"]) == false)
check("空串 bundleID → 不忽略", HotkeyIgnorePolicy.isIgnored(bundleID: "  ", rules: ["com.a.b"]) == false)
check("规则里有空串 → 跳过不误伤", HotkeyIgnorePolicy.isIgnored(bundleID: "com.x", rules: ["", "  "]) == false)

print("\n=== 2. 精确匹配（大小写不敏感、去空白）===\n")
check("精确命中", HotkeyIgnorePolicy.isIgnored(bundleID: "com.apple.Safari",
                                               rules: ["com.apple.Safari"]) == true)
check("大小写不敏感命中", HotkeyIgnorePolicy.isIgnored(bundleID: "com.apple.safari",
                                                       rules: ["COM.apple.Safari"]) == true)
check("规则两端空白被 trim 后命中",
      HotkeyIgnorePolicy.isIgnored(bundleID: "com.apple.Safari",
                                  rules: ["  com.apple.Safari\n"]) == true)
check("bundleID 两端空白也被 trim",
      HotkeyIgnorePolicy.isIgnored(bundleID: " com.apple.Safari ",
                                   rules: ["com.apple.Safari"]) == true)
check("不匹配 → 不忽略",
      HotkeyIgnorePolicy.isIgnored(bundleID: "com.apple.TextEdit",
                                   rules: ["com.apple.Safari"]) == false)
check("多规则中任一命中即忽略",
      HotkeyIgnorePolicy.isIgnored(bundleID: "com.microsoft.VSCode",
                                   rules: ["com.apple.Safari", "com.microsoft.VSCode"]) == true)

print("\n=== 3. 前缀通配（以 * 结尾）===\n")
check("前缀规则命中",
      HotkeyIgnorePolicy.isIgnored(bundleID: "com.microsoft.VSCode",
                                   rules: ["com.microsoft.*"]) == true)
check("前缀规则大小写不敏感命中",
      HotkeyIgnorePolicy.isIgnored(bundleID: "com.microsoft.VSCode.Insiders",
                                   rules: ["COM.microsoft.*"]) == true)
check("只是字符串包含不算（必须锚定前缀）",
      HotkeyIgnorePolicy.isIgnored(bundleID: "net.microsoft.app",
                                   rules: ["com.microsoft.*"]) == false)
check("前缀不匹配 → 不忽略",
      HotkeyIgnorePolicy.isIgnored(bundleID: "org.gnu.Emacs",
                                   rules: ["com.microsoft.*"]) == false)
check("单独 * → 全部忽略",
      HotkeyIgnorePolicy.isIgnored(bundleID: "anything.at.all", rules: ["*"]) == true)
check("单独 * 配空白 bundleID 仍不忽略",
      HotkeyIgnorePolicy.isIgnored(bundleID: nil, rules: ["*"]) == false)
check("* 不在末尾时按字面量精确匹配（不命中）",
      HotkeyIgnorePolicy.isIgnored(bundleID: "com.a.x",
                                   rules: ["com.*.x"]) == false)
check("* 不在末尾但字面量相同 → 精确命中",
      HotkeyIgnorePolicy.isIgnored(bundleID: "com.*.x",
                                   rules: ["com.*.x"]) == true)

// MARK: - 4. Preferences：忽略列表读写

print("\n=== 4. ignoredBundleIdentifiers 持久化与清洗 ===\n")
let suiteName = "com.aisnap.probe.hotkeyignore"
guard let store = UserDefaults(suiteName: suiteName) else {
    print("无法创建测试用 UserDefaults suite"); exit(1)
}
store.removePersistentDomain(forName: suiteName)
let prefs = Preferences(defaults: store)

check("缺省为空数组", prefs.ignoredBundleIdentifiers == [], "\(prefs.ignoredBundleIdentifiers)")

prefs.ignoredBundleIdentifiers = ["com.a", "com.b"]
let reopened1 = Preferences(defaults: store)
check("写后跨实例读回", reopened1.ignoredBundleIdentifiers == ["com.a", "com.b"],
      "\(reopened1.ignoredBundleIdentifiers)")

// 脏数据清洗：空白、空串、重复
store.set(["com.a", " com.a ", "", "   ", "com.b", "com.b"], forKey: "ignoredBundleIdentifiers")
let cleaned = Preferences(defaults: store).ignoredBundleIdentifiers
check("读出时去空白/去空串/去重", cleaned == ["com.a", "com.b"], "\(cleaned)")

// MARK: - 5. Preferences：托盘按键动作

print("\n=== 5. tray 动作持久化 ===\n")
check("左键缺省 .menu", prefs.trayLeftAction == .menu, "\(prefs.trayLeftAction)")
check("右键缺省 .menu", prefs.trayRightAction == .menu, "\(prefs.trayRightAction)")
check("中键缺省 .noAction", prefs.trayMiddleAction == .noAction, "\(prefs.trayMiddleAction)")
check("动作数量为 5", TrayClickAction.allCases.count == 5,
      "\(TrayClickAction.allCases.count)")
check("displayName 非空且互不相同",
      Set(TrayClickAction.allCases.map(\.displayName)).count == TrayClickAction.allCases.count)

prefs.trayLeftAction = .regionCapture
prefs.trayRightAction = .history
prefs.trayMiddleAction = .windowCapture
let reopened2 = Preferences(defaults: store)
check("左键写读 .regionCapture", reopened2.trayLeftAction == .regionCapture)
check("右键写读 .history", reopened2.trayRightAction == .history)
check("中键写读 .windowCapture", reopened2.trayMiddleAction == .windowCapture)

store.set("bogus-action", forKey: "trayLeftAction")
check("脏值回缺省 .menu", Preferences(defaults: store).trayLeftAction == .menu)

// MARK: - 6. resetToDefaults 覆盖新键

print("\n=== 6. resetToDefaults ===\n")
Preferences(defaults: store).resetToDefaults()
let afterReset = Preferences(defaults: store)
check("忽略列表清空", afterReset.ignoredBundleIdentifiers == [])
check("左键回 .menu", afterReset.trayLeftAction == .menu)
check("右键回 .menu", afterReset.trayRightAction == .menu)
check("中键回 .noAction", afterReset.trayMiddleAction == .noAction)

// 清理测试域（与 prefs_probe 同一手法；run_all.sh 退出后还会兜底删文件）
CFPreferencesAppSynchronize(suiteName as CFString)
store.removePersistentDomain(forName: suiteName)
CFPreferencesAppSynchronize(suiteName as CFString)
try? FileManager.default.removeItem(
    at: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suiteName).plist"))

print("\n=== 结果 ===")
if failures == 0 {
    print("通过 全部断言，失败 0 项")
} else {
    print("通过 部分断言，失败 \(failures) 项")
    exit(1)
}
