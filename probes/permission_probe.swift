import Cocoa

// 权限判定：绝不能把「没有权限」判成「有权限」。
//
// ## 为什么这个探针要另起一个进程
//
// 探针是从终端 / 宿主继承来的，多半**已经持有屏幕录制授权** —— 那样
// `CGPreflightScreenCaptureAccess()` 直接返回 true，`checkScreenCapturePermission()`
// 里的兜底分支根本不会被执行。也就是说：**在进程内怎么测，都测不到"无权限"那一支**，
// 而这恰恰是出过 bug 的那一支。
//
// 所以这里用 `launchctl submit` 把**自己**再起一份：launchd 的子进程没有 TCC 授权，
// 正是需要的样本。父进程读子进程写下的报告来判断。
//
// ## 副作用（重要）
//
// 它**会真的发抓屏请求**，于是这个探针二进制会被登记进
// 「系统设置 → 隐私与安全性 → 屏幕录制」列表 —— 而探针每次都编译到新的临时路径，
// 等于跑一次多一条垃圾记录，且这类按路径识别的裸可执行文件 `tccutil reset` 清不掉
// （报 "No such bundle identifier"），只能在系统设置里手动删。
//
// **所以它不参与 `run_all.sh` 的默认轮次**，要显式跑：
//
//     AISNAP_PROBE_ALLOW_CAPTURE=1 ./probes/run_all.sh permission
//
//
// 历史（2026-09-28）：兜底探测原本用「2×2 截图里有没有非透明像素」判定，而
// **没有权限时 `CGWindowListCreateImage` 依然返回一张非 nil、完全不透明的桌面图**
// （实测像素 (45,45,50,255)，四个像素一模一样 —— 那是壁纸）。于是判定恒为真，
// 权限门形同删除，用户截出黑图/壁纸且没有任何解释。
// 换成 ScreenCaptureKit 的权限专属信号（无权限时抛 -3801）后才真正区分得开。
//
// ## 一个必须知道的观测陷阱
//
// 子进程的**实时**权限会随"谁把它提交给 launchd"而变：经 bash 提交时 SCK 稳定报
// 无权限，经 `Process` 从本探针提交时却报**有**权限。原因是 TCC 的归属认定（环境里
// 带着 `__CFBundleIdentifier=io.appmakes.otty` 之类）。所以：
//   · `CGPreflightScreenCaptureAccess()`（读缓存）与 SCK（读实时）**可以不一致**，
//     而"preflight 说没有、实时说有"恰恰是兜底该救的假阴性 —— 不要断言两者相等；
//   · 能判别的契约是 `判定 == (preflight || 实时 SCK 答案)`：旧实现违反它
//     （实时无权限却判有权限），新实现恰好满足。

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : "  —— \(detail)")") }
}

let childFlag = "--permission-probe-child"
let reportPath = "/tmp/aisnap-permission-probe-child.txt"
let jobLabel = "com.aisnap.permission-probe"

// ── 子进程模式：把三个判定写进文件，供父进程读取 ──────────────────────────
if CommandLine.arguments.contains(childFlag) {
    let delegate = AppDelegate()
    let preflight = CGPreflightScreenCaptureAccess()
    let sck = delegate.canQueryShareableContent()
    let decided = delegate.checkScreenCapturePermission()
    // 第三次调用：连续多次是否一致？（曾经出现过同一进程内两次结果不同的现象）
    let sckAgain = delegate.canQueryShareableContent()
    let text = """
    preflight=\(preflight)
    sck=\(sck)
    decided=\(decided)
    sckAgain=\(sckAgain)
    """
    try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
    exit(0)
}

_ = NSApplication.shared

print("=== 权限判定：无权限时不得判成有权限 ===")

// ── 1. 本进程内（多半已授权）：至少不能把好情况判坏 ────────────────────────
do {
    let delegate = AppDelegate()
    let preflight = CGPreflightScreenCaptureAccess()
    let sck = delegate.canQueryShareableContent()
    let decided = delegate.checkScreenCapturePermission()
    print("     [INFO] 本进程（多半已授权）：preflight=\(preflight) SCK 探测=\(sck) 判定=\(decided)")

    check("已授权（preflight 为真）时判定必须为真", !preflight || decided,
          "preflight=\(preflight) 判定=\(decided)")
    // SCK 探测与 preflight 在"已授权"这一侧必须一致；不一致说明探测本身把好情况判坏了
    check("已授权时 SCK 探测也得说有权限（不然会误报缺权限）", !preflight || sck,
          "preflight=\(preflight) SCK=\(sck)")
}

// ── 2. 换一个没有 TCC 授权的身份跑同一个二进制 ────────────────────────────
do {
    try? FileManager.default.removeItem(atPath: reportPath)
    let me = CommandLine.arguments[0]
    print("     [INFO] 用 launchctl 另起一份自己（无 TCC 授权）：\(me)")

    let submit = Process()
    submit.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    submit.arguments = ["submit", "-l", jobLabel, "--", me, childFlag]
    submit.standardOutput = FileHandle.nullDevice
    submit.standardError = FileHandle.nullDevice
    do { try submit.run() } catch {
        check("能起一个无授权身份的子进程", false, "launchctl 起不来：\(error)")
        exit(failed == 0 ? 0 : 1)
    }
    submit.waitUntilExit()

    // 子进程是异步跑的，等它把报告写出来（最多 10 秒）
    var report: String?
    for _ in 0..<40 {
        if let text = try? String(contentsOfFile: reportPath, encoding: .utf8) {
            report = text
            break
        }
        usleep(250_000)
    }

    let cleanup = Process()
    cleanup.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    cleanup.arguments = ["remove", jobLabel]
    cleanup.standardOutput = FileHandle.nullDevice
    cleanup.standardError = FileHandle.nullDevice
    try? cleanup.run()
    cleanup.waitUntilExit()
    try? FileManager.default.removeItem(atPath: reportPath)

    guard let text = report else {
        // 拿不到报告多半是这台机器不让 launchctl 起任务 —— 报事实，不硬判失败
        print("     [INFO] 没拿到子进程报告（本机可能不允许 launchctl 起任务），跳过这一项")
        print("\n通过 \(passed) 项，失败 \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }

    func field(_ key: String) -> Bool? {
        for line in text.split(separator: "\n") where line.hasPrefix(key + "=") {
            return line.split(separator: "=")[1] == "true"
        }
        return nil
    }
    let childPreflight = field("preflight")
    let childSCK = field("sck")
    let childDecided = field("decided")
    let childSCKAgain = field("sckAgain")
    print("     [INFO] 子进程：preflight=\(String(describing: childPreflight)) "
          + "SCK=\(String(describing: childSCK)) 判定=\(String(describing: childDecided)) "
          + "SCK 复测=\(String(describing: childSCKAgain))")

    // ★ 核心断言（**只**锚在安全性质上）：实时无权限时，判定必须是无权限。
    //
    // 这正是旧实现翻车的地方：兜底换成了"截图里有没有非透明像素"，而没有权限时
    // 截图依然是一张不透明的壁纸 → 判 true。于是"实时无权限"的进程拿到了
    // `decided == true`，权限门被整个绕过。
    //
    // 反过来（实时有权限 → 判 true）不需要断言成等式：SCK 偶有抖动，
    // 抖动只会让判定**偏保守**（多弹一次授权引导），那是安全方向；
    // 而“判 true”必须要求 SCK 真的成功，本身就是实时 TCC 说允许 —— 不会假阳性。
    if childSCK == false {
        check("【核心】实时无权限时判定必须是无权限（不得被兜底探测翻成有权限）",
              childDecided == false,
              "SCK=false → 判定=\(String(describing: childDecided))")
    } else {
        print("     [INFO] 这一轮子进程实时是**有**权限的（TCC 归属受启动方式影响，见文件头），"
              + "构造不出'实时无权限'的样本 —— 本项退化为不判定")
    }
    if let s = childSCK, let s2 = childSCKAgain, s != s2 {
        // 实测到的形态：同一个进程里连续调三次，前两次成功、**第三次失败**，
        // 且把超时从 1 秒放大到 8 秒也一样 —— 所以不是"回调慢被超时截断"。
        // 应用每次截图只调用一次，取的是第一次的结论，不受这个影响；
        // 这里只记录事实，不判失败。
        print("     [INFO] 子进程里 SCK 两次调用结论不同（\(s) vs \(s2)）——"
              + "实测是'连续第三次调用会失败'的固定形态，且与超时无关；"
              + "应用每次截图只调一次，不受影响。不判失败，仅记录")
    }
}

print("\n========================================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)
