import Foundation
import ServiceManagement

/// 开机自动启动。
///
/// **只以系统的注册状态为唯一来源，不往 UserDefaults 里再存一份。**
/// 这个开关的真实状态在 `SMAppService` 手里 —— 用户可以在「系统设置 → 通用 →
/// 登录项与扩展」里直接关掉，本地再存一份必然与系统不一致，界面就会说谎。
/// 这与「设置窗口只放没有别的入口的设置」是同一条原则的另一面。
enum LaunchAtLogin {

    /// 状态查询的结果，顺便带上"为什么不能用"。
    enum Status: Equatable {
        case enabled
        case disabled
        /// 需要用户去系统设置里批准（注册成功但被系统拦着）
        case requiresApproval
        /// 不是从真正的 .app 里运行的
        case unavailable
    }

    /// 必须从完整的 `.app`  bundle 里运行：`SMAppService.mainApp` 注册的是**当前 bundle**，
    /// `swift run` 出来的可执行文件没有 bundle，无从注册。这一条也要如实告诉用户，
    /// 而不是让开关点了没反应。
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var status: Status {
        guard isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    /// 设置开机启动。返回 nil 表示成功，否则是给用户看的失败原因。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard isAvailable else {
            return "这个开关需要从「应用程序」里的 AISnap 使用。"
                + "当前是直接运行的构建产物（没有应用包），系统无处注册。"
        }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            return "设置失败：\(error.localizedDescription)"
        }

        if status == .requiresApproval {
            return "已提交注册，还需到「系统设置 → 通用 → 登录项与扩展」里允许 AISnap。"
        }
        return nil
    }
}
