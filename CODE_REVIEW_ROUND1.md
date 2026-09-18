# AISnap 代码 Review 报告（第一轮）

> **历史文档**：这是第一轮 review 的原始报告，其结论已被仓库根目录的
> `CODE_REVIEW.md`（三轮 review 汇总，含对本轮若干判断的修正与证伪）取代。
> 保留它是为了记录提交 `7172e73`（修复 24 项缺陷）的证据链。
> **请以 `CODE_REVIEW.md` 为准。**

- **仓库**: `/Users/ola/fengyong/ai-snap`
- **范围**: `Sources/**/*.swift`、`Package.swift`、`build.sh`、`README.md`
- **方法**: 三轮静态审阅 + 本机可执行 probe（macOS 26.5.1，三显示器，Swift 6.0.3）
- **Probe 路径**: `probes/review/probe_round1_basics.swift`、
  `probes/review/probe_round2_stroke_clear.swift`、
  `probes/review/probe_round3_bridge_types.swift`

```bash
cd /Users/ola/fengyong/ai-snap
swift probes/review/probe_round1_basics.swift
swift probes/review/probe_round2_stroke_clear.swift
swift probes/review/probe_round3_bridge_types.swift
```

---

## 1. 项目概览

macOS 菜单栏截图标注工具（Swift + AppKit + SPM，无第三方依赖）。

| 组件 | 职责 |
|------|------|
| `main.swift` | 应用入口 |
| `AppDelegate.swift` | 状态栏、截图调度、权限 |
| `ScreenCapture.swift` | 区域/窗口捕获 |
| `RegionSelectionWindow.swift` | 全屏选区覆盖层 |
| `AnnotationWindow/View` | 标注 UI 与画布交互 |
| `HitTestBuffer.swift` | 双图层 Color Picking |
| `Models.swift` | 形状/样式/Undo 模型 |

核心架构（双图层 Color Picking）本身合理；问题集中在**多显示器坐标系、导出路径、UI 布局与窗口生命周期**。

---

## 2. 核验方法与修正记录

### 2.1 Probe 覆盖

| Probe | 验证点 | 结果 |
|-------|--------|------|
| P1 | `kCGWindowBounds as? [String: CGFloat]` | 通过（30/30） |
| P2 | PID / CGWindowID 桥接 | 通过 |
| P3 | 选区 `stroke` → `.clear` | 内侧描边被擦，外侧残留 |
| P4 | `pullsDown` 贴纸 `indexOfSelectedItem` | action 路径下可用 |
| P5 | 多屏选区覆盖 | 仅 main 可拖选 |
| P6 | 副屏 capture 坐标 | `codeCG` ≠ `correctCG` |
| P7 | 窗口命中 Y 翻转 | `main==primary` 时正确，否则错误 |
| P8 | 工具栏宽度累加 | 约 916pt，最小窗 780pt，溢出 ~136pt |
| P9 | HitTest Y 翻转 | 与 AppKit 左下原点一致 |
| P10 | Spotlight 导出路径 | 确认会带出黄虚线 |
| P11 | Undo `.add` 级联 | LIFO 下基本不可达（latent） |

### 2.2 第一轮结论修正

| 原判断 | 修正后 |
|--------|--------|
| 字典 cast 可能一直失败 | **否**，当前 OS 桥接成功 |
| 选区边框被完全抹掉 | **否**，仅内侧半截；外侧 ~0.75pt 仍在 |
| 贴纸 pullsDown 必挂 | **降级**，index 映射可用但 API 脆弱 |
| Undo 添加不级联必现 bug | **降级为 latent**（LIFO 下子 add 先弹出） |
| ESC 因 firstResponder 失效 | **偏重**，contentView 可成为 first responder |
| Spotlight 附着全坏 | **收窄**，仅 perimeter 锚点失效 |

---

## 3. 问题清单（按严重度）

### P0 — 必须修

#### P0-1 多显示器：区域选区 UI 与 capture 坐标

**位置**
- `RegionSelectionWindow.swift:12-13`（仅覆盖 `NSScreen.main`）
- `RegionSelectionWindow.swift:38-50`（副屏只有暗遮罩，无拖选）
- `RegionSelectionWindow.swift:69-75`（Y 翻转 + 未加 screen origin）
- `ScreenCapture.swift:35-37`（窗口命中用 `NSScreen.main.height`）

**现象**
- 副屏无法拖选。
- 若选区不在主屏（origin≠0,0），`captureRect` 的 x/y 都错。
- `NSScreen.main` 是键盘焦点屏，不是主屏；焦点在副屏时窗口截图 Y 翻转错误。

**Probe 证据（本机 3 屏）**

```text
screens[0] (0,0,2560×1080) main
screens[2] (-2048,288,2048×1152)

correctCG = (-1948, 642, 200, 100)
codeCG    = (100, 1002, 200, 100)
```

**建议**
1. 选区窗口覆盖全部 `NSScreen.screens`，每屏可拖选。
2. 统一转换：`cgY = primary.frame.maxY - nsMaxY`，`cgX = globalNS.minX`（含 screen origin）。
3. 窗口命中：`let primaryH = NSScreen.screens[0].frame.maxY`，勿用 `NSScreen.main`。

---

#### P0-2 导出带上 Spotlight 编辑器黄虚线

**位置**
- `Models.swift:1033-1044`（`SpotlightShape.draw` 无条件描边）
- `AnnotationView.swift:1014-1018`（`compositeImage` 调用 `obj.draw`）

**现象**  
启用聚光灯后保存/复制的 PNG 含黄色虚线框（编辑器 UI 泄漏进导出）。

**建议**  
协议增加 `draw(in:forExport:)`，或导出时对 Spotlight 只应用遮罩、不描边。

---

### P1 — 高优先级

#### P1-1 工具栏绝对布局溢出

**位置**: `AnnotationWindow.swift:151-291`

**证据**: 内容宽度约 **916pt**，窗口最小宽 **780pt**，溢出 **~136pt**。

**建议**: Auto Layout / `NSStackView` / 溢出菜单；或随窗口宽度隐藏低频控件。

---

#### P1-2 激活策略与 mainMenu 生命周期

**位置**
- `AppDelegate.swift:9`（`.accessory`）
- `AnnotationWindow.swift:145-146`（改 `.regular` + 重写 `NSApp.mainMenu`）
- 关窗无还原逻辑

**现象**
- 第一次标注后 Dock 图标常驻。
- 与 `Info.plist` 的 `LSUIElement=true` 语义冲突。
- 多次开窗覆盖全局菜单；关窗后 menu target 可能指向已关闭窗口。

**建议**
- `windowWillClose` 时 `setActivationPolicy(.accessory)`。
- MainMenu 在 AppDelegate 创建一次；标注窗只更新 first responder 路径。

---

#### P1-3 窗口截图失败静默

**位置**: `AppDelegate.swift:97-100`

**现象**: `captureWindowUnderMouse() == nil` 时无任何提示（无权限、命中失败、延迟不够）。

**建议**: 失败时 `NSAlert`；可增加短暂倒计时/高亮覆盖层。

---

#### P1-4 `CGWindowListCreateImage` 已弃用

**位置**: `ScreenCapture.swift:40,53`

**现象**: macOS 14+ deprecated；当前 26.x 仍可用，属前瞻风险。

**建议**: 迁移 ScreenCaptureKit（`SCScreenshotManager` / `SCContentFilter`）。

---

#### P1-5 箭头样式功能无 UI

**位置**
- `Models.swift:75-118`（6 种预设）
- `AnnotationView.swift:21`（`currentArrowStyle`）
- `AnnotationWindow` 无任何样式切换控件

**现象**: README 写了 6 种箭头样式，用户无法切换。

**建议**: 工具栏增加样式 Popup/Segmented control。

---

### P2 — 中优先级

#### P2-1 选区边框被 clear 内侧擦掉

**位置**: `RegionSelectionWindow.swift:143-152`

**现象**: 先 `stroke` 再 `setBlendMode(.clear)` + `fill`，描边内侧被清空，边框变细/残缺。

**建议**: 先 `clear` 挖空选区，再 `stroke` 边框。

---

#### P2-2 贴纸 `pullsDown` + `indexOfSelectedItem` 脆弱

**位置**: `AnnotationWindow.swift:234-243, 381-387`

**Probe**: action 触发时 index 正确；仍依赖未严格文档化的行为。

**建议**: `pullsDown=false`，或菜单项设 `tag`，action 读 `sender.selectedItem?.tag`。

---

#### P2-3 删除选中伪造 NSEvent

**位置**: `AnnotationWindow.swift:414-422`

**建议**: `AnnotationView` 暴露 `deleteSelected()`，菜单直接调用。

---

#### P2-4 `build.sh` 写死 arm64 路径

**位置**: `build.sh:6`

```bash
BUILD_DIR=".build/arm64-apple-macosx/release"
```

**建议**: 从 `swift build -c release --show-bin-path` 取路径；或 `uname -m` 拼接。

---

#### P2-5 `.build/` 未忽略且已进 git

**位置**: `.gitignore` 仅 `AISnap.app`

**建议**:

```gitignore
.build/
.DS_Store
*.dmg
AISnap.app
```

（若 DMG 需要保留则调整。）

---

#### P2-6 保存 PNG 静默失败

**位置**: `AnnotationWindow.swift:446`（`try?`）

**建议**: catch 后 Alert；成功可短暂状态提示。

---

#### P2-7 区域选择重入无保护

**位置**: `AppDelegate.swift:78-84`

**现象**: 连续触发「区域截图」覆盖 `regionSelectionWindow`，旧覆盖层可能残留。

**建议**: 已存在则 `orderOut`/取消后再创建。

---

#### P2-8 Spotlight perimeter 附着不解析

**位置**
- `AnnotationView.swift:896-933`（`computePerimeterParameter` 无 Spotlight）
- `AnnotationView.swift:937-957`（`resolveAttachmentPosition` 无 Spotlight）

**现象**: 周长锚点参数恒 0，resolve 为 nil，箭头端点冻结。snapPoint 附着仍正常。

**建议**: 实现 Spotlight 的 perimeter 参数，或 detect 阶段禁止 perimeter 附着。

---

### P3 — 低优先级 / 工程

| ID | 问题 | 位置 |
|----|------|------|
| P3-1 | Undo `.add` 无 `cascadeDelete`（LIFO 下 latent） | `AnnotationView.swift:451-458` |
| P3-2 | 合成导出用 `lockFocus`，Retina/跨屏 scale 可能不准 | `AnnotationView.swift:1005-1024` |
| P3-3 | 调试面板强制占 50% 宽，无开关 | `AnnotationWindow.swift:17-84` |
| P3-4 | 无全局热键（仅菜单） | 全局 |
| P3-5 | Undo 栈无上限 | `AnnotationView.swift:36-37` |
| P3-6 | 无单元测试 | 仓库 |
| P3-7 | 权限授予后不提示可能需重启 | `AppDelegate.swift:17-22` |
| P3-8 | `HitTestBuffer` 中 `CGContext(...)!` | `HitTestBuffer.swift:16-23` |
| P3-9 | color key 回绕理论冲突 | `HitTestBuffer.swift:33-40` |
| P3-10 | 无签名/公证的分发 DMG | `build.sh` |

---

## 4. 已验证正确的部分

- HitTestBuffer Y 翻转与 AppKit 左下原点一致（probe P9）。
- 双图层 Color Picking 设计清晰，关闭抗锯齿正确。
- 删除路径级联记录 + `cascadeDelete` 完整。
- `kCGWindowBounds` / PID / WindowID 类型桥接在当前系统可用。
- 主屏（origin 0,0）上区域截图 Y 翻转公式在 `NSScreen.main == screens[0]` 时正确。
- 附着箭头在父对象 move/rotate/scale 时通过 `updateAttachedArrows` 更新。

---

## 5. 建议修复顺序

```text
1. P0-1  多屏选区 + 坐标统一（primary.maxY）
2. P0-2  Spotlight 导出去掉编辑器描边
3. P1-1  工具栏布局
4. P1-2  激活策略 / mainMenu
5. P1-3  窗口截图失败反馈
6. P2-1  选区描边顺序
7. P2-2..P2-8  贴纸 tag、公开删除 API、build 路径、gitignore 等
8. P1-4  ScreenCaptureKit 迁移（可单独立项）
9. P3    工程化与测试
```

---

## 6. 手工回归清单（修完后）

| 步骤 | 期望 |
|------|------|
| 副屏拖选区域截图 | 可选区，内容对齐、无偏移 |
| 焦点在副屏时窗口截图 | 正确捕获鼠标下窗口 |
| 聚光灯 + 保存/复制 | 无黄色虚线框 |
| 小区域截图打开标注窗 | 工具栏完整可点 |
| 开标注窗再关闭 | Dock 不再显示 AISnap |
| 拖选中观察选区 | 四边虚线完整清晰 |
| 贴纸下拉选择后点击画布 | 出现对应表情 |
| 箭头样式切换后绘制 | 样式生效 |
| 无权限/点空处窗口截图 | 有错误提示而非无响应 |

---

## 7. 总结

架构选型（AppKit + Color Picking）匹配截图标注场景，几何/命中层实现质量较高。主要债务在：

1. **坐标系统未按多显示器设计**（最严重）；
2. **编辑态视觉泄漏进导出**；
3. **工具栏与窗口生命周期的 AppKit 使用不完整**；
4. **工程脚本与仓库卫生**。

建议优先处理 P0，再收口 P1/P2；P1-4（ScreenCaptureKit）可作为兼容性专项。
