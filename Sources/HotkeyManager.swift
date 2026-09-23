import Cocoa
import Carbon.HIToolbox

/// 一个全局快捷键的配置：虚拟键码 + 修饰键。
///
/// 用 Carbon 的整数表示（而不是 `NSEvent`），因为 `RegisterEventHotKey` 要的就是它；
/// 存进 `UserDefaults` 也更直接（两个 Int，不需要归档）。
struct HotkeyConfig: Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon 修饰键位掩码（cmdKey / shiftKey / optionKey / controlKey）
    var carbonModifiers: UInt32

    /// 展示用字符串，如 `⌘⇧A` 会渲染成 **`⇧⌘A`**。
    ///
    /// 顺序按 Apple HIG 的固定惯例：**⌃⌥⇧⌘**（Control、Option、Shift、Command）。
    /// 所以 ⌘⇧A 的正确写法是 `⇧⌘A`（对照：访达「新建文件夹」显示为 ⇧⌘N）。
    /// 这里不是随手排的 —— 顺序错了会和系统菜单里的写法不一致，看起来很业余。
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += HotkeyConfig.keyName(for: keyCode)
        return s
    }

    /// 至少要含 ⌘ 或 ⌃。
    ///
    /// **不能只要求「有修饰键」**：`⇧A` / `⌥A` / `⇧⌥A` 这类组合一旦注册成全局快捷键，
    /// 就会在系统范围内抢掉正常打字 —— 打大写 A、或某些键盘布局下输入特殊字符时
    /// 被静默吞掉并转而触发截图。这个症状很隐蔽，用户几乎不可能联想到是截图工具
    /// 干的。离屏测试正好覆盖到这个洞（最初只判 `carbonModifiers != 0`）。
    ///
    /// ⌘ 与 ⌃ 是「命令型」修饰键，不参与常规文本输入，作为全局快捷键是安全的。
    var isUsable: Bool {
        let hasCommandLike = carbonModifiers & UInt32(cmdKey) != 0
            || carbonModifiers & UInt32(controlKey) != 0
        return hasCommandLike && HotkeyConfig.keyName(for: keyCode) != "?"
    }

    /// 虚拟键码 → 可读名称。
    ///
    /// 只覆盖常用的字母、数字与少量符号键：完整的键码表需要 `UCKeyTranslate`
    /// 配合当前键盘布局才能得到正确字符（同一个键码在不同布局下字母不同），
    /// 而快捷键实际只会用到这些。未覆盖的键返回 `?`，`isUsable` 会拒绝它。
    static func keyName(for keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "空格", UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
        ]
        return map[keyCode] ?? "?"
    }

    /// `NSEvent.ModifierFlags` → Carbon 位掩码。供录键界面使用。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// 系统截图快捷键占用的组合（⌘⇧3 / 4 / 5 / 6），注册前用来提醒用户避让。
    static let systemScreenshotCombos: Set<HotkeyConfig> = [
        HotkeyConfig(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey | shiftKey)),
        HotkeyConfig(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey)),
        HotkeyConfig(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey | shiftKey)),
        HotkeyConfig(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: UInt32(cmdKey | shiftKey)),
    ]
}

/// 全局快捷键注册器。
///
/// 用 Carbon 的 `RegisterEventHotKey`：**零第三方依赖**，且不需要辅助功能权限
/// （`NSEvent.addGlobalMonitorForEvents` 需要授权，且只能被动观察、无法拦截）。
/// 这是 macOS 上注册全局快捷键的标准做法。
///
/// 注意一个容易被忽视的点：Carbon 只装**一个**事件处理器，用 `EventHotKeyID`
/// 区分是哪个快捷键。所以这里维护 id → handler 的映射，而不是每个快捷键装一个
/// 处理器（后者的事件处理器是 C 函数指针，无法捕获上下文）。
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// 注册失败的原因，供 UI 提示。
    enum RegistrationError: Error {
        /// 被**别的应用**占了
        case keyAlreadyTaken(String)
        /// 被**本应用内的另一个动作**占了。与上一条是不同的问题：
        /// 混在一起报「已被其它应用占用」，会把人引去排查别的应用，
        /// 而真正的原因是自己在设置窗口里把两个动作设成了同一个组合。
        case keyUsedByAnotherAction(String)
        case systemError(OSStatus, String)
        case unusableCombination(String)
    }

    private struct Registration {
        let id: UInt32
        let ref: EventHotKeyRef?
        let config: HotkeyConfig
        let handler: () -> Void
    }

    private var registrations: [Registration] = []
    private var handlersByID: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    /// Carbon 用四字符署名区分不同应用的热键；`ASNP` = AISnap。
    private let signature: OSType = 0x41534E50

    private init() {}

    // MARK: - 注册

    /// 注册一个全局快捷键。
    ///
    /// 同一个组合**不会被重复注册**：先查本应用已注册的表，命中就明确报出是
    /// "本应用内已被另一个动作占用"。此前这里没有查重，于是第二个动作会拿到
    /// Carbon 的 `eventHotKeyExistsErr`，被报成"已被**其它应用**占用"——
    /// 而实际是我们自己占的，用户会去关别的应用，永远修不好。
    ///
    /// 注：这里**不是**「后注册的顶掉旧的」。顶掉会让先注册的那个动作静默失效，
    /// 用户只知道"某个快捷键没反应"，比直接报错难查得多。
    @discardableResult
    func register(_ config: HotkeyConfig, handler: @escaping () -> Void) throws -> UInt32 {
        guard config.isUsable else {
            throw RegistrationError.unusableCombination(config.displayString)
        }
        if registrations.contains(where: { $0.config == config }) {
            throw RegistrationError.keyUsedByAnotherAction(config.displayString)
        }
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(config.keyCode, config.carbonModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            // eventHotKeyExistsErr = -9878：该组合已被别的应用占用
            if status == OSStatus(eventHotKeyExistsErr) {
                throw RegistrationError.keyAlreadyTaken(config.displayString)
            }
            throw RegistrationError.systemError(status, config.displayString)
        }

        handlersByID[id] = handler
        registrations.append(Registration(id: id, ref: ref, config: config, handler: handler))
        return id
    }

    /// 撤掉全部已注册快捷键。改键或退出前调用。
    func unregisterAll() {
        for reg in registrations {
            if let ref = reg.ref { UnregisterEventHotKey(ref) }
            handlersByID.removeValue(forKey: reg.id)
        }
        registrations.removeAll()
    }

    /// 已成功注册的快捷键（供 UI 回显「实际生效」的组合）。
    var registeredConfigs: [HotkeyConfig] {
        registrations.map(\.config)
    }

    // MARK: - 分发

    fileprivate func dispatch(id: UInt32) {
        handlersByID[id]?()
    }

    /// 只会装一次。Carbon 的事件处理器是 C 函数指针，拿不到 `self`，
    /// 因此通过单例转发。
    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            guard err == noErr else { return err }
            // 回到主线程：快捷键回调会触发 UI 操作（开窗口、截图）
            DispatchQueue.main.async {
                HotkeyManager.shared.dispatch(id: hotKeyID.id)
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}

/// 从偏好读出快捷键并（重新）注册。
///
/// 抽成独立类型而不是写在 `AppDelegate` 里：**启动时注册**与**改键后重注册**
/// 是同一件事，两处各写一遍迟早会不一致（例如一处忘了先 `unregisterAll`，
/// 就会出现「旧键还能用」的幽灵快捷键）。
enum HotkeyRegistration {
    /// 注册全部快捷键，返回需要提示给用户的问题（组合被占用等）。
    /// 返回空数组表示全部成功。
    @discardableResult
    static func applyAll(regionHandler: @escaping () -> Void,
                         windowHandler: @escaping () -> Void) -> [String] {
        let manager = HotkeyManager.shared
        manager.unregisterAll()      // 必须先撤旧的，否则改键后旧键仍然生效

        var problems: [String] = []

        do {
            try manager.register(Preferences.shared.regionCaptureHotkey, handler: regionHandler)
        } catch {
            problems.append(describe(error, action: "区域截图"))
        }

        do {
            try manager.register(Preferences.shared.windowCaptureHotkey, handler: windowHandler)
        } catch {
            problems.append(describe(error, action: "窗口截图"))
        }

        return problems
    }

    private static func describe(_ error: Error, action: String) -> String {
        guard let error = error as? HotkeyManager.RegistrationError else {
            return "\(action)的快捷键注册失败"
        }
        switch error {
        case .keyAlreadyTaken(let combo):
            return "「\(action)」的 \(combo) 已被其它应用占用，请换一个组合"
        case .keyUsedByAnotherAction(let combo):
            return "「\(action)」的 \(combo) 已用于本应用的另一个动作，请换一个组合"
        case .systemError(let status, let combo):
            return "「\(action)」的 \(combo) 注册失败（系统错误 \(status)）"
        case .unusableCombination(let combo):
            return "「\(action)」的 \(combo) 不能作为全局快捷键（需含 ⌘ 或 ⌃，且需为字母、数字或常用符号）"
        }
    }
}

// MARK: - 忽略程序策略

/// 判定「当前前台应用在忽略列表里时，全局截图热键是否应跳过动作」。
///
/// v1 用**一份共享列表**同时作用于区域/窗口两个截图热键 —— 真实诉求是
/// 「在终端 / IDE / 游戏里别劫持我的按键」，按热键分别配表的需求很弱，留待后续。
///
/// ⚠️ 平台限制：Carbon 的 `RegisterEventHotKey` 注册后按键即被系统吞掉，
/// 这里的「忽略」只能做到**我们不触发动作**，无法把按键再透传给前台应用。
/// 真正的透传需要 CGEventTap + 辅助功能权限，与本应用「少要权限」的原则冲突，不做。
/// 默认组合（⌃⌘A / ⌃⌘W）足够冷门，被吞也没有实际影响。
enum HotkeyIgnorePolicy {

    /// - Parameters:
    ///   - bundleID: 当前前台应用的 bundle identifier（来自 NSWorkspace）
    ///   - rules: 忽略规则；精确匹配大小写不敏感；以 `*` 结尾表示前缀匹配
    ///            （如 `com.microsoft.VSCode*`）；单独一个 `*` 表示全部忽略
    /// - Returns: 该应用是否应被忽略
    static func isIgnored(bundleID: String?, rules: [String]) -> Bool {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty, !rules.isEmpty else {
            return false
        }

        for rawRule in rules {
            let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.isEmpty else { continue }

            if rule == "*" {
                return true
            }
            if rule.hasSuffix("*") {
                let prefix = String(rule.dropLast())
                if !prefix.isEmpty,
                   bundleID.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                    return true
                }
                continue
            }
            if bundleID.caseInsensitiveCompare(rule) == .orderedSame {
                return true
            }
        }
        return false
    }
}
