# SCK 迁移改动评审（2026-09-11 当日工作区改动）

> 评审对象：`/Users/ola/WorkBuddy/coding/ai-snap-analysis/ai-snap` 工作区（HEAD 仍为 ac21da6，改动未提交）
> 改动范围：`Package.swift` · `build.sh` · `Sources/ScreenCapture.swift`（重构为 façade）· 新增 `Sources/Capture/`（3 文件）· `AppDelegate` / `RegionSelectionWindow` 调用点 · README / DESIGN.md
> 对照基准：`ScreenCaptureKit-迁移实施方案.md` 的 Step 1–6 与 V1–V7 清单

---

## 总裁定

**架构执行正确，构建干净，但有一步被跳过：方案自己标注为"关键路径"的 Step 3（7 项运行时自检）一项都没做。** 当前代码注释里的"已实测"仅指 `swiftc -typecheck` 级别的编译期确认，运行时行为（坐标原点、Retina 分辨率）仍是未知数——而其中 V4 恰好悬着全方案最大的一颗未爆弹（见下）。**建议 V1–V7 完成前不要合并/分发。**

---

## 一、做对的部分（对照方案逐条核实）

| 方案要求 | 落实情况 |
|---------|---------|
| 最小改动切面：窗口枚举逻辑不动 | ✅ `windowIDUnderMouse()` 与旧 `captureWindowUnderMouse` 的 Z 序命中逻辑逐行一致，只是返回 `windowID` 而不再自己抓图 |
| CGWindowID 无损对接 | ✅ `content.windows.first(where: { $0.windowID == windowID })`（头文件依据正确） |
| Retina 陷阱（width/height 默认 1920×1080） | ✅ filter 路径显式 `config.width/height = 尺寸 × filter.pointPixelScale` + `captureResolution = .best` |
| 版本路由 | ✅ 15.2+ 走 `captureImage(in:)`，14.0–15.1 走 filter 路径，`@available` 标注正确 |
| `.boundsIgnoreFraming` 等价物 | ✅ `ignoreShadowsSingleWindow = true` |
| 修复"静默失败"旧缺陷 | ✅ 权限被拒 → `showPermissionAlert()`；结构化 `ScreenCaptureError` |
| 回滚通道 | ✅ `CaptureProviderLegacy.swift` 完整保留，标注 deprecated， façade 注释写明切换方法 |
| 部署目标三处同步 | ✅ Package.swift v14 / build.sh LSMinimumSystemVersion 14.0 / README"要求 macOS 14+" |
| 文档同步 | ✅ README 的分工图、文件表、代码统计（3,460 行/11 文件，数字准确）；DESIGN.md 补了迁移动机与头文件证据 |
| 编译 | ✅ `swift build` 通过，无警告 |

---

## 二、问题清单（按严重度）

### P1 · Step 3 未执行，V1–V7 全部未验证 —— 合并阻塞项

- 两条路径的运行时行为都没有实测证据。已尝试代跑自检：终端无屏幕录制权限，无法代验（自检脚本已归档：`review_code/sck_selfcheck.swift`）。
- **风险最大的具体项 V4**：`SCScreenshotManager.captureImage(in:)` **没有 configuration 参数**，只能用默认 `SCStreamConfiguration`——也就是默认 width/height（1920×1080）生效的那一套。15.2+ 是首选主路径，**极可能输出非 Retina 甚至固定 1080p 的截图**。filter 路径显式设了尺寸没问题，但主路径没设也没法设——只能实测后决定：要么确认它内部按 rect×scale 输出（保留），要么砍掉 in-rect 路径统一走 filter。
- V1（`captureImage(in:)` 坐标原点方向）同样只能实测：若为左下原点，区域截图全部错位。
- **执行建议**：给状态栏菜单加"按住 Option 显示的 SCK 自检"项（方案 Step 3 原设计），跑 V1/V4/V5/V7 各一次，10 分钟内可出结论。

### P2 · 15.2+ 主路径无法排除自身覆盖窗口

`captureImage(in:)` 没有 filter 参数，排除不了 AISnap 自己的选区覆盖层——这正是 80ms 延迟被保留的原因。而 filter 路径已经排除自身窗口，其实不需要 delay。两条路径行为不一致；根治靠"先截后选"重构（已在路线图），短期可接受，但建议在 `RegionSelectionWindow` 的注释里写明这个因果。

### P2 · 原样保留的枚举逻辑 = 原样保留的已知 bug

`windowIDUnderMouse()` 一行未动，意味着**副屏 Y 翻转 bug 也一行未动**（`NSScreen.main` 高度做全局翻转，鼠标在副屏时取错窗口）。迁移决策本身没错（方案明确"坐标换算不动"），但请把它记在账上：多屏修复时这个函数还在原地。

### P3 · 小问题

1. `AppDelegate.swift:110` 附近：`catch { NSSound.beep() }` 但注释说"与旧行为一致地静默忽略"——beep 不是静默。行为其实更好，改注释即可。
2. `ScreenCaptureError.userMessage` 定义后全项目无人使用（AppDelegate 用的是自己 `showPermissionAlert` 里的文案）。要么让 alert 用它，要么删掉，别留死 API。
3. DESIGN.md 新增句"macOS 15+ 上继续使用会触发反复的权限弹窗"沿用了调研文档的表述——反复弹窗仅发生在无签名/不稳定 code identity 的二进制上（AISnap 当前恰好是，所以动机成立），但写成普遍事实不准确，建议收敛为"对未签名分发包会反复触发权限弹窗，且 API 已 obsolete 随时可能移除"。
4. filter 路径 `displays.first(where: intersects)` 对跨屏 rect 只取第一个相交屏，`sourceRect` 可能越界——当前选区只在单屏交互，可接受，建议加一行注释声明该限制。

---

## 三、验收清单（合并前）

- [ ] V1：`captureImage(in:)` 输出内容确为请求矩形（原点/方向）
- [ ] V4：200×200 点 → 输出 400×400 px（Retina）；若否，砍 in-rect 路径
- [ ] V5：关权限后得到 `.permissionDenied` 并弹引导（而非静默）
- [ ] V7：双屏环境区域/窗口截图各验一次（预期：当前仅主屏正确，已知限制）
- [ ] 窗口截图对比旧版：`SCWindow.frame` 是否含阴影（若含，评估 config 尺寸与内容的轻微拉伸）
- [ ] 标注全链路回归：截图 → 箭头 → 选中/移动/旋转/撤销 → 导出
- [ ] 三个小修：beep 注释、userMessage 二选一、DESIGN.md 表述收敛
