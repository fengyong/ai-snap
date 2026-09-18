import Foundation

/// 版本号。
///
/// **为什么不能拿字符串比大小**：`"1.10.0" < "1.9.0"` 在字符串比较下是成立的
/// （因为 `'1' == '1'`、`'0' < '9'`），而它显然是错的。这个错误只在版本号进入两位数
/// 之后才暴露 —— 也就是发布十几次之后，那时改动成本最高。
///
/// 逐段按数字比较、缺位补 0，并遵循 SemVer 的预发布规则（`1.0.0-beta` 早于 `1.0.0`）。
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]
    let isPrerelease: Bool
    /// 预发布的标识序列（SemVer §9）：`1.0.0-beta.3` → `["beta", "3"]`；正式版为空
    let prereleaseIdentifiers: [String]
    /// 原始字符串（去掉前导 v 之后），用于展示
    let raw: String

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }

        // 拆出「数字主体」与「预发布后缀」：1.0.0-beta.3 → 1.0.0 + beta.3
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(halves[0])
        let prerelease = halves.count > 1 ? String(halves[1]) : ""
        self.isPrerelease = !prerelease.isEmpty
        self.prereleaseIdentifiers = prerelease.isEmpty
            ? []
            : prerelease.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        var numbers: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            // 只取开头的连续数字："1a" 视为 1，空的或纯非数字的段视为无效版本
            let digits = part.prefix { $0.isNumber }
            guard let value = Int(digits) else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }

        self.components = numbers
        self.raw = text
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            // 缺位补 0："1.0" 与 "1.0.0" 视为同一个版本
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        // 数字部分相同 → 按 SemVer §11.4 比较预发布标识
        return comparePrerelease(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) ?? false
    }

    /// SemVer §11.4 的预发布优先级比较。返回 nil 表示"数字部分相同且预发布完全相同"。
    ///
    /// 之前只存了一个 `isPrerelease` 布尔量，于是 `1.0.0-alpha` 与 `1.0.0-beta`
    /// 会被判成相等（两者都"是预发布"、数字部分又相同），
    /// 与注释里声称遵循的 SemVer 不符 —— 后果是新预发布版发布后不提示更新。
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Bool? {
        if lhs.isEmpty && rhs.isEmpty { return nil }
        if lhs.isEmpty { return false }        // 正式版 > 预发布版
        if rhs.isEmpty { return true }         // 预发布版 < 正式版

        for i in 0..<max(lhs.count, rhs.count) {
            guard i < lhs.count else { return true }    // 前缀相同则字段少的一方优先级低
            guard i < rhs.count else { return false }
            let l = lhs[i], r = rhs[i]
            switch (Int(l), Int(r)) {
            case let (ln?, rn?):
                if ln != rn { return ln < rn }
            case (_?, nil):
                return true                             // 数字标识 < 字母标识
            case (nil, _?):
                return false
            default:
                if l != r { return l < r }              // 都是字母 → ASCII 字典序
            }
        }
        return nil
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var description: String { raw }
}

/// 更新清单（appcast）的内容。
///
/// 刻意用一个**普通 JSON 文件**而不是 Sparkle 的 XML appcast：
/// 本项目目前没有代码签名与公证（M5-1 未做），而"下载并替换自身"这条路在未签名的
/// 情况下会被 Gatekeeper 拦下 —— 装了 Sparkle 也只能走到一半。
/// 所以这里只做「检查有没有新版本 + 把用户送到下载页」，这半步在未签名时也是完整可用的。
struct UpdateManifest: Codable, Equatable {
    let version: String
    let downloadURL: String
    let notes: String?
}

enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case updateAvailable(current: String, version: String, downloadURL: String, notes: String?)
    case failed(reason: String)
}

/// 应用自身的信息。
enum AppInfo {
    /// 打包成 .app 后由脚本写入的兜底版本号。
    ///
    /// **这是版本号的单一来源之外的一份拷贝，发布流程里必须与打包脚本保持一致。**
    /// 之所以需要它：`swift run` 直接跑出来的可执行文件没有 Info.plist，
    /// 读 `CFBundleShortVersionString` 会拿到 nil。
    static let bundledFallbackVersion = "0.1.0"

    /// 当前版本：优先读 Info.plist，读不到才回落到兜底值。
    static var currentVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.trimmingCharacters(in: .whitespaces).isEmpty {
            return version
        }
        return bundledFallbackVersion
    }
}

enum UpdateChecker {
    /// 清单地址：优先用用户填的，没填（或不合法）则视为「尚未配置」。
    ///
    /// 这里要**主动校验 scheme**：`URL(string:)` 对非 ASCII 很宽容，
    /// `"不是地址"` 也能被它解析成一个没有 scheme 的相对地址 —— 那样会一路走到
    /// 网络请求才失败，用户看到的是"unsupported URL"这种看不懂的报错。
    /// 在入口处挡掉，才能给出"还没配置更新地址"这种说得清的提示。
    static var configuredFeedURL: URL? {
        let raw = Preferences.shared.updateFeedURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return nil }
        // file:// 没有 host（探针就靠它跑通整条链路），http(s) 必须有
        if scheme != "file" && (url.host ?? "").isEmpty { return nil }
        return url
    }

    // MARK: - 判定（纯函数，可离屏测）

    /// 用当前版本与清单内容判断该做什么。
    ///
    /// 抽成纯函数的意义：这一段的分支不少（版本解析失败、远端更旧、远端相同、
    /// 远端更新的 URL 非法），而**走网络**才能跑到的话，绝大部分分支一辈子不会被测到。
    static func evaluate(current: String, manifest: UpdateManifest) -> UpdateCheckResult {
        guard let remote = AppVersion(manifest.version) else {
            return .failed(reason: "更新清单里的版本号看不懂：\(manifest.version)")
        }
        guard let local = AppVersion(current) else {
            // 本地版本号读不出来（例如从 SwiftPM 直接跑、没有 Info.plist）。
            // 这时报「未知」比报「已是最新」诚实 —— 后者会让用户以为检查过了。
            return .failed(reason: "读不到当前版本号")
        }

        if remote > local {
            guard URL(string: manifest.downloadURL) != nil else {
                return .failed(reason: "更新清单里的下载地址无效：\(manifest.downloadURL)")
            }
            return .updateAvailable(current: local.raw, version: remote.raw,
                                    downloadURL: manifest.downloadURL,
                                    notes: manifest.notes)
        }
        // 远端更旧或相同都算"已是最新"：远端更旧通常意味着用户跑的是内测版，
        // 这时提示"有新版本"反而会把人劝退到旧版
        return .upToDate(current: local.raw)
    }

    // MARK: - 取清单

    /// 拉取清单并判定。`completion` 在主线程回调。
    ///
    /// 用 `URLSession` 直接读 `file://` 也可以（探针就是靠这个跑通整条链路的），
    /// 所以这里不额外做协议判断。
    static func check(currentVersion: String,
                      feedURL: URL,
                      session: URLSession = .shared,
                      completion: @escaping (UpdateCheckResult) -> Void) {
        var request = URLRequest(url: feedURL)
        // 更新清单必须每次都拿最新的，缓存会让人"检查了但还是提示旧版本"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        session.dataTask(with: request) { data, _, error in
            let result: UpdateCheckResult
            if let error = error {
                result = .failed(reason: "网络请求失败：\(error.localizedDescription)")
            } else if let data = data {
                do {
                    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                    result = evaluate(current: currentVersion, manifest: manifest)
                } catch {
                    result = .failed(reason: "更新清单格式不对（应为 JSON，含 version 与 downloadURL）")
                }
            } else {
                result = .failed(reason: "没有拿到数据")
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
