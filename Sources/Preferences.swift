import Cocoa
import Carbon.HIToolbox

/// 用户偏好的持久化存取。
///
/// **为什么单独抽一层**：此前线宽、颜色、箭头样式、线型、水印、调色板每次重启
/// 全部重置（技术债 P1）。这些值散落在 `AnnotationView` 与 `AnnotationWindow`，
/// 若各处直接读写 `UserDefaults`，键名、类型、缺省值就会散到三处 —— 尤其缺省值
/// 一旦改动，老用户的已存值与代码里的初值会不一致，且没有任何编译错误提示。
///
/// 这里做**单一来源**：键名与缺省值只出现一次。读取统一走
/// `object(forKey:)` + 类型判断，而不是 `double(forKey:)` / `bool(forKey:)` ——
/// 后者对缺失键返回 0 / false，会把「从未设置过」当成一个有效的用户选择。
///
/// **写入时机**：由各属性的 `didSet` 触发，不需要显式保存调用。
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults

    /// 允许注入其他 `UserDefaults` 实例，便于隔离与测试。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 键与缺省值

    private enum Key: String {
        case lineWidth
        case lineStyle
        case colorHex
        case arrowStyleIndex
        case paletteIndex
        case lastToolTag
        case watermarkEnabled
        case watermarkText
        case hotkeyRegion
        case hotkeyWindow
        case updateFeedURL
        case autoCheckUpdates
        case recordHistory
    }

    /// 缺省值集中在这里。改动这一处即同时改变「新用户初值」与「老用户缺键回退值」。
    enum Defaults {
        static let lineWidth: CGFloat = 15
        static let lineStyle: LineStyle = .solid
        static let color: NSColor = .red
        static let arrowStyleIndex = 0
        static let paletteIndex = 0
        static let lastToolTag = 0
        static let watermarkEnabled = false
        static let watermarkText = "AISnap"
        /// 保留截图历史。默认开（它的用处就是"忘了保存还能找回来"）。
        /// 关掉时**连写盘都不发生** —— 截图常含敏感内容，用户对"我没保存的东西
        /// 却躺在磁盘上"的接受度因人而异，开关必须是真的开关。
        static let recordHistory = true

        /// 默认快捷键。刻意避开两类组合：
        ///
        /// 1. 系统截图的 ⌘⇧3 / 4 / 5 / 6（注册前还会再拦一道，见
        ///    `HotkeyConfig.systemScreenshotCombos`）；
        /// 2. **主流应用的菜单快捷键** —— 这一点更要紧：全局热键是会话级独占的，
        ///    注册之后那个组合就不再到达任何前台应用。最初的默认值用的是 ⌘⇧W，
        ///    而它在浏览器里是"关闭窗口"级别的高频键，等于开箱就把用户常用快捷键
        ///    静默劫持掉，症状还完全不像截图工具干的（与"⇧A 吞掉打大写"同一类）。
        ///
        /// ⌃⌘ 这一族几乎没有应用占用，两个动作也保持一致（成对的键不一致会很别扭）。
        static let regionCaptureHotkey = HotkeyConfig(keyCode: UInt32(kVK_ANSI_A),
                                                     carbonModifiers: UInt32(cmdKey | controlKey))
        static let windowCaptureHotkey = HotkeyConfig(keyCode: UInt32(kVK_ANSI_W),
                                                     carbonModifiers: UInt32(cmdKey | controlKey))
    }

    // MARK: - 线宽

    var lineWidth: CGFloat {
        get {
            guard let v = defaults.object(forKey: Key.lineWidth.rawValue) as? Double else {
                return Defaults.lineWidth
            }
            return CGFloat(v)
        }
        set { defaults.set(Double(newValue), forKey: Key.lineWidth.rawValue) }
    }

    // MARK: - 线型

    var lineStyle: LineStyle {
        get {
            guard let raw = defaults.string(forKey: Key.lineStyle.rawValue),
                  let style = LineStyle(rawValue: raw) else {
                return Defaults.lineStyle
            }
            return style
        }
        set { defaults.set(newValue.rawValue, forKey: Key.lineStyle.rawValue) }
    }

    // MARK: - 颜色

    var color: NSColor {
        get {
            guard let hex = defaults.string(forKey: Key.colorHex.rawValue),
                  let color = Preferences.color(fromHex: hex) else {
                return Defaults.color
            }
            return color
        }
        set { defaults.set(Preferences.hexString(from: newValue), forKey: Key.colorHex.rawValue) }
    }

    // MARK: - 箭头样式（按预设下标存，预设增删时下标可能错位 → 越界即回缺省）

    var arrowStyle: ArrowStyle {
        get {
            guard let idx = defaults.object(forKey: Key.arrowStyleIndex.rawValue) as? Int,
                  idx >= 0, idx < ArrowStyle.allPresets.count else {
                return ArrowStyle.allPresets[Defaults.arrowStyleIndex]
            }
            return ArrowStyle.allPresets[idx]
        }
        set {
            guard let idx = ArrowStyle.allPresets.firstIndex(where: { $0 == newValue }) else { return }
            defaults.set(idx, forKey: Key.arrowStyleIndex.rawValue)
        }
    }

    // MARK: - 调色板

    var paletteIndex: Int {
        get {
            guard let idx = defaults.object(forKey: Key.paletteIndex.rawValue) as? Int,
                  idx >= 0, idx < ColorPalette.allPalettes.count else {
                return Defaults.paletteIndex
            }
            return idx
        }
        set { defaults.set(newValue, forKey: Key.paletteIndex.rawValue) }
    }

    // MARK: - 上次使用的工具

    /// 存的是工具栏按钮的 tag，而不是 `DrawingTool` 本身 ——
    /// `DrawingTool` 带关联值（`.stamp(.heart)`）且不是 `RawRepresentable`，
    /// 存下标更简单；有效性由使用方对着 `toolbarTools` 校验。
    var lastToolTag: Int {
        get { defaults.object(forKey: Key.lastToolTag.rawValue) as? Int ?? Defaults.lastToolTag }
        set { defaults.set(newValue, forKey: Key.lastToolTag.rawValue) }
    }

    // MARK: - 水印

    var watermarkEnabled: Bool {
        get { defaults.object(forKey: Key.watermarkEnabled.rawValue) as? Bool ?? Defaults.watermarkEnabled }
        set { defaults.set(newValue, forKey: Key.watermarkEnabled.rawValue) }
    }

    var watermarkText: String {
        get { defaults.string(forKey: Key.watermarkText.rawValue) ?? Defaults.watermarkText }
        set { defaults.set(newValue, forKey: Key.watermarkText.rawValue) }
    }

    /// 把水印配置一次性读出来（`WatermarkConfig` 里只有 text / enabled 两项是可编辑偏好，
    /// 其余（字号、颜色、平铺、角度）目前没有 UI 入口，保持代码里的默认值）。
    var watermarkConfig: WatermarkConfig {
        var config = WatermarkConfig()
        config.text = watermarkText
        config.enabled = watermarkEnabled
        return config
    }

    // MARK: - 全局快捷键

    var regionCaptureHotkey: HotkeyConfig {
        get { hotkey(Key.hotkeyRegion, fallback: Defaults.regionCaptureHotkey) }
        set { setHotkey(newValue, Key.hotkeyRegion) }
    }

    var windowCaptureHotkey: HotkeyConfig {
        get { hotkey(Key.hotkeyWindow, fallback: Defaults.windowCaptureHotkey) }
        set { setHotkey(newValue, Key.hotkeyWindow) }
    }

    /// 存成 `"keyCode:modifiers"` 单个字符串，而不是两个键 ——
    /// 一次读写的原子性更好，且校验只需一处。
    private func hotkey(_ key: Key, fallback: HotkeyConfig) -> HotkeyConfig {
        guard let raw = defaults.string(forKey: key.rawValue) else { return fallback }
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt32(String(parts[0])),
              let modifiers = UInt32(String(parts[1])) else { return fallback }
        let config = HotkeyConfig(keyCode: keyCode, carbonModifiers: modifiers)
        // 已存值也可能是坏的（手改 plist、旧版本格式）→ 不可用就回缺省，
        // 否则会注册一个「只有一个修饰键」之类的组合出来
        return config.isUsable ? config : fallback
    }

    private func setHotkey(_ config: HotkeyConfig, _ key: Key) {
        defaults.set("\(config.keyCode):\(config.carbonModifiers)", forKey: key.rawValue)
    }

    // MARK: - 截图历史

    var recordHistory: Bool {
        get { defaults.object(forKey: Key.recordHistory.rawValue) as? Bool ?? Defaults.recordHistory }
        set { defaults.set(newValue, forKey: Key.recordHistory.rawValue) }
    }

    // MARK: - 更新

    /// 更新清单（appcast）地址。留空表示"还没有发布渠道"，此时只保留手动检查入口。
    ///
    /// 做成可配置而不是写死在代码里：这个地址在应用发布之前是不存在的，
    /// 写死一个占位地址只会制造"检查更新永远失败"的假象。
    var updateFeedURL: String {
        get { defaults.string(forKey: Key.updateFeedURL.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.updateFeedURL.rawValue) }
    }

    /// 启动时自动检查更新。**默认关闭** —— 一个截图工具在用户没要求的情况下
    /// 每次启动都去联网，是很不礼貌的行为。
    var automaticallyChecksForUpdates: Bool {
        get {
            defaults.object(forKey: Key.autoCheckUpdates.rawValue) as? Bool ?? false
        }
        set { defaults.set(newValue, forKey: Key.autoCheckUpdates.rawValue) }
    }

    // MARK: - 恢复默认

    /// 清空所有已存偏好，回到 `Defaults`。
    func resetToDefaults() {
        for key in [Key.lineWidth, Key.lineStyle, Key.colorHex, Key.arrowStyleIndex,
                    Key.paletteIndex, Key.lastToolTag, Key.watermarkEnabled, Key.watermarkText,
                    Key.hotkeyRegion, Key.hotkeyWindow, Key.updateFeedURL, Key.autoCheckUpdates,
                    Key.recordHistory] {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    // MARK: - 颜色与十六进制互转

    /// 转换为 `#RRGGBB`。先落到 sRGB 再取分量 —— 直接用 `redComponent` 取
    /// 非 RGB 色彩空间（如灰度、命名色）的颜色会抛异常。
    static func hexString(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#FF0000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func color(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }
}
