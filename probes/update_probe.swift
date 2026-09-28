import Cocoa

// 更新检查的验证。核心风险是**版本号比较**：
// `"1.10.0" < "1.9.0"` 在字符串比较下成立、在版本语义下是错的 ——
// 而这个错误要等到版本号进两位数才暴露（也就是发布十几次之后）。
// 另一处是分支覆盖：「远端更旧」「本地版本读不出来」「下载地址非法」这些分支
// 只有走网络才能跑到的话，一辈子不会被测到，所以判定逻辑抽成了纯函数。
//
// 链接**真实的** UpdateChecker.swift + Preferences.swift + Models.swift
// （Preferences 依赖 HotkeyConfig / LineStyle 等，因此一并链上）。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  [\(detail)]")") }
}

_ = NSApplication.shared

// MARK: - 1. 版本号解析

print("=== 1. 版本号解析 ===")
do {
    check("1.2.3 → 三段", AppVersion("1.2.3")?.components == [1, 2, 3])
    check("v1.2.3 的前导 v 被吃掉", AppVersion("v1.2.3")?.components == [1, 2, 3])
    check("V1.2.3 大写 V 同样", AppVersion("V1.2.3")?.components == [1, 2, 3])
    check("1.2 → 两段", AppVersion("1.2")?.components == [1, 2])
    check("1 → 一段", AppVersion("1")?.components == [1])
    check("前后空白被忽略", AppVersion("  1.2.3  ")?.components == [1, 2, 3])

    let pre = AppVersion("1.0.0-beta.2")
    check("预发布后缀被识别", pre?.components == [1, 0, 0] && pre?.isPrerelease == true,
          "\(String(describing: pre))")
    check("正式版不带预发布标记", AppVersion("1.0.0")?.isPrerelease == false)

    check("空串无效", AppVersion("") == nil)
    check("纯字母无效", AppVersion("abc") == nil)
    check("1..2 里的空段无效（不会当成 0）", AppVersion("1..2") == nil)
    check("v 后面什么都没有无效", AppVersion("v") == nil)
    check("1.2.x 里纯非数字的段无效", AppVersion("1.2.x") == nil)
    // 数字后面跟字母是允许的（构建元数据之类），取开头数字
    check("1.2.3a → 取 1.2.3", AppVersion("1.2.3a")?.components == [1, 2, 3],
          "\(String(describing: AppVersion("1.2.3a")?.components))")
}

// MARK: - 2. 版本号比较

print("\n=== 2. 版本号比较 ===")
do {
    func less(_ a: String, _ b: String) -> Bool {
        guard let x = AppVersion(a), let y = AppVersion(b) else { return false }
        return x < y
    }
    func equal(_ a: String, _ b: String) -> Bool {
        guard let x = AppVersion(a), let y = AppVersion(b) else { return false }
        return x == y
    }

    // ★ 这一条是整段逻辑存在的理由
    check("1.10.0 > 1.9.0（字符串比较会得出相反结论）", less("1.9.0", "1.10.0"))
    check("1.0.10 > 1.0.9", less("1.0.9", "1.0.10"))
    check("2.0 > 1.99.99", less("1.99.99", "2.0"))
    check("3.0 < 3.0.1（缺位补 0）", less("3.0", "3.0.1"))
    check("1.0 == 1.0.0", equal("1.0", "1.0.0"))
    check("1 == 1.0.0.0", equal("1", "1.0.0.0"))
    check("1.0.0-beta < 1.0.0（预发布早于正式）", less("1.0.0-beta", "1.0.0"))
    check("1.0.0-beta < 1.0.1", less("1.0.0-beta", "1.0.1"))
    check("0.9 < 1.0", less("0.9", "1.0"))
    check("相同版本既不小于也不大于", !less("1.2.3", "1.2.3") && !less("1.2.3", "1.2.3"))
}

// MARK: - 3. 判定（纯函数，覆盖各分支）

print("\n=== 3. 判定分支 ===")
do {
    let manifestNew = UpdateManifest(version: "1.5.0",
                                     downloadURL: "https://example.com/a.dmg",
                                     notes: "修复了若干问题")
    let manifestSame = UpdateManifest(version: "1.2.0",
                                      downloadURL: "https://example.com/a.dmg", notes: nil)
    let manifestOld = UpdateManifest(version: "0.9.0",
                                     downloadURL: "https://example.com/a.dmg", notes: nil)
    let manifestBadVersion = UpdateManifest(version: "最新版",
                                            downloadURL: "https://example.com/a.dmg", notes: nil)
    let manifestBadURL = UpdateManifest(version: "9.9.9",
                                        downloadURL: "", notes: nil)

    check("远端更新 → updateAvailable",
          UpdateChecker.evaluate(current: "1.2.0", manifest: manifestNew)
            == .updateAvailable(current: "1.2.0", version: "1.5.0",
                                downloadURL: "https://example.com/a.dmg",
                                notes: "修复了若干问题"))
    check("远端相同 → upToDate",
          UpdateChecker.evaluate(current: "1.2.0", manifest: manifestSame)
            == .upToDate(current: "1.2.0"))
    check("远端更旧 → upToDate（用户跑的是内测版，不该被劝回旧版）",
          UpdateChecker.evaluate(current: "1.2.0", manifest: manifestOld)
            == .upToDate(current: "1.2.0"))
    check("远端版本号看不懂 → failed（不是静默当作最新）",
          UpdateChecker.evaluate(current: "1.2.0", manifest: manifestBadVersion).isFailure)
    // downloadURL 会被 NSWorkspace.open 打开，所以 scheme 必须受限（只放 https）。
    // 以前只判 `URL(string:) != nil`，`file:` / `javascript:` / 自定义 scheme 都能过。
    func verdict(_ url: String) -> UpdateCheckResult {
        UpdateChecker.evaluate(current: "1.0.0",
                               manifest: UpdateManifest(version: "2.0.0",
                                                        downloadURL: url, notes: nil))
    }
    func isUpdate(_ r: UpdateCheckResult) -> Bool {
        if case .updateAvailable = r { return true }
        return false
    }
    for bad in ["file:///tmp/evil.dmg", "javascript:alert(1)",
                "http://example.com/a.dmg", "myapp://do-something",
                "https:no-host", "/relative/path.dmg"] {
        check("下载地址 \(bad) 必须被拒（它会被 NSWorkspace.open 打开）",
              !isUpdate(verdict(bad)), "\(verdict(bad))")
    }
    check("对照：https 且带主机的下载地址照常放行",
          isUpdate(verdict("https://example.com/a.dmg")),
          "\(verdict("https://example.com/a.dmg"))")

    check("远端更新但下载地址为空 → failed",
          UpdateChecker.evaluate(current: "1.2.0", manifest: manifestBadURL).isFailure)
    check("本地版本号读不出来 → failed（报失败比报已是最新诚实）",
          UpdateChecker.evaluate(current: "开发版", manifest: manifestNew).isFailure)

    // 同一段数字但预发布：1.2.0-beta 收到 1.2.0 应该提示更新
    check("1.2.0-beta 收到 1.2.0 → 提示更新",
          UpdateChecker.evaluate(current: "1.2.0-beta",
                                 manifest: UpdateManifest(version: "1.2.0",
                                                          downloadURL: "https://e.com/a",
                                                          notes: nil))
            != .upToDate(current: "1.2.0-beta"))
}

// MARK: - 4. 清单地址配置

print("\n=== 4. 清单地址（留空 / 非法都不检查）===")
do {
    let prefs = Preferences.shared
    let saved = prefs.updateFeedURL
    defer { prefs.updateFeedURL = saved }

    prefs.updateFeedURL = ""
    check("留空 → nil（不发起请求）", UpdateChecker.configuredFeedURL == nil)

    prefs.updateFeedURL = "   "
    check("只有空白 → nil", UpdateChecker.configuredFeedURL == nil)

    prefs.updateFeedURL = "https://example.com/latest.json"
    check("正常地址 → 能解析出 URL",
          UpdateChecker.configuredFeedURL?.host == "example.com",
          "\(String(describing: UpdateChecker.configuredFeedURL))")

    prefs.updateFeedURL = "不是地址"
    check("非法地址 → nil（URL(string:) 对非 ASCII 很宽容，必须自己校验 scheme）",
          UpdateChecker.configuredFeedURL == nil,
          "\(String(describing: UpdateChecker.configuredFeedURL))")

    prefs.updateFeedURL = "ftp://example.com/latest.json"
    check("非 http(s)/file 的 scheme → nil",
          UpdateChecker.configuredFeedURL == nil,
          "\(String(describing: UpdateChecker.configuredFeedURL))")

    prefs.updateFeedURL = "https://"
    check("有 scheme 但没有主机 → nil",
          UpdateChecker.configuredFeedURL == nil,
          "\(String(describing: UpdateChecker.configuredFeedURL))")

    prefs.updateFeedURL = "http://example.com/latest.json"
    check("http 也接受（内网自建更新源）",
          UpdateChecker.configuredFeedURL?.scheme == "http")
}

// MARK: - 5. 端到端：真的取一次清单（用 file:// 走完整链路）

print("\n=== 5. 端到端：读一份真实的清单文件，跑通整条链路 ===")
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("aisnap-update-probe-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func runCheck(feed: URL) -> UpdateCheckResult? {
        var result: UpdateCheckResult?
        UpdateChecker.check(currentVersion: "1.0.0", feedURL: feed) { result = $0 }
        // 等主队列上的回调（URLSession 的回调在后台，completion 会回主队列）
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result
    }

    // ① 正常清单
    let good = dir.appendingPathComponent("good.json")
    try? Data("""
        {"version": "2.1.0", "downloadURL": "https://example.com/AISnap-2.1.0.dmg",
         "notes": "新增取色器与 OCR"}
        """.utf8).write(to: good)
    let goodResult = runCheck(feed: good)
    check("读到清单并判定为有更新",
          goodResult == .updateAvailable(current: "1.0.0", version: "2.1.0",
                                         downloadURL: "https://example.com/AISnap-2.1.0.dmg",
                                         notes: "新增取色器与 OCR"),
          "\(String(describing: goodResult))")

    // ② 旧版本清单
    let old = dir.appendingPathComponent("old.json")
    try? Data(#"{"version": "0.0.1", "downloadURL": "https://example.com/a.dmg"}"#.utf8)
        .write(to: old)
    check("远端更旧 → 已是最新",
          runCheck(feed: old) == .upToDate(current: "1.0.0"),
          "\(String(describing: runCheck(feed: old)))")

    // ③ 文件损坏
    let broken = dir.appendingPathComponent("broken.json")
    try? Data("这不是 JSON".utf8).write(to: broken)
    check("清单不是 JSON → failed",
          runCheck(feed: broken)?.isFailure == true,
          "\(String(describing: runCheck(feed: broken)))")

    // ④ 文件不存在
    check("清单文件不存在 → failed",
          runCheck(feed: dir.appendingPathComponent("nope.json"))?.isFailure == true)
}

extension UpdateCheckResult {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

print("\n=== 6. HTTP 状态码要说清楚（不能一律报「清单格式不对」）===")
do {
    /// 桩：不发真实请求，直接回一个指定状态码 + 一段非 JSON 的 body。
    /// 真实服务器返回 404/500 时通常也带 HTML 错误页 —— 那正是会被误报成
    /// 「清单格式不对」的形态，把「地址写错了 / 服务端挂了」误导成「格式问题」。
    final class StubHTTP: URLProtocol {
        static var status = 404
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<html>Not Found</html>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func checkStatus(_ code: Int) -> UpdateCheckResult? {
        StubHTTP.status = code
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTP.self]
        var result: UpdateCheckResult?
        UpdateChecker.check(currentVersion: "1.0.0",
                            feedURL: URL(string: "https://example.com/latest.json")!,
                            session: URLSession(configuration: config)) { result = $0 }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result
    }

    func failureReason(_ r: UpdateCheckResult?) -> String {
        if case .failed(let why) = r { return why }
        return "(不是 failed)"
    }

    let notFound = checkStatus(404)
    check("404 要报出 HTTP 404，而不是「清单格式不对」",
          failureReason(notFound).contains("404"), failureReason(notFound))
    check("404 必须是 failed（不能静默当作已是最新）",
          notFound?.isFailure == true, failureReason(notFound))

    let serverError = checkStatus(500)
    check("500 同样要报出状态码",
          failureReason(serverError).contains("500"), failureReason(serverError))

    // 对照组：200 + 同样的非 JSON body，这时才该是「格式不对」
    let ok = checkStatus(200)
    check("对照：200 且 body 不是 JSON 时，才报「清单格式不对」",
          failureReason(ok).contains("格式"), failureReason(ok))
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
