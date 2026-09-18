# AISnap 代码 Review 报告（第四轮 · 修复后独立复核）

- **仓库**: `/Users/ola/fengyong/ai-snap`
- **复核对象**: `7172e73`（"修复 review 发现的 24 项缺陷"）之后的当前实现
- **范围**: `Sources/` 全部 8 个文件 3724 行、`probes/` 探针套件、构建脚本
- **方法**: 逐行阅读 + **黑盒探针**（真实 `NSEvent` 驱动 `AnnotationView`、读导出图真实像素、
  与暴力搜索的几何真值对比）。所有结论均可由 `./probes/run_all.sh post_fix` 复跑。
- **环境**: macOS 26.5.1 / Swift 6.0.3 / 三显示器（均为 2x）

---

## 0. 结论摘要

**上一轮的 24 项修复经复核基本成立**：仓库自带的 13 个探针中 12 个「复现缺陷数 = 0」，
唯一的例外是明确被推迟的 P0-1（ScreenCaptureKit 迁移）。

**但独立复核发现了 10 条新缺陷**，其中 2 条属于「上一轮已识别、却从未真正落地」，
1 条是**不可恢复的数据丢失**。

| 级别 | 缺陷 | 一句话影响 |
|------|------|-----------|
| **P0-1** | 聚光灯的编辑器虚线边框仍被画进导出图 | 上一轮 P0-2 **从未实施**；保存/复制的 PNG 带黄虚线 |
| **P0-2** | 程序化关窗后激活策略残留 `.regular` | 再截图若被取消/失败，Dock 图标与菜单栏**永久**残留 |
| **P0-3** | 亚像素拖拽摧毁箭头附着且不留撤销 | 2x 屏上 1 物理像素的手抖 → 附着**不可恢复**地丢失 |
| P1-1 | 拖拽聚光灯时遮罩被叠加两次 | 预览亮度 0.204 vs 成品 0.451，所见非所得 |
| P1-2 | 线宽滑块每次连续回调都入 undo 栈 | 拖一次滑块要按几十次 Cmd+Z |
| P1-3 | 椭圆 `nearestPerimeterPoint` 是径向投影不是最近点 | 偏心椭圆吸附点偏差最大 **48.2 pt** |
| P2-1 | 贴纸工具在工具栏重建后高亮成「箭头」 | 点「换色」后工具状态显示错误 |
| P2-2 | `isFullyTransparent` 把 1x1 不透明图判为全透明 | 权限兜底探测在 **1x 屏**上恒报「无权限」 |
| P2-3 | `hasEdits` 只看撤销栈不看画布 | 删光标注后仍弹「放弃当前标注？」 |
| P3-1 | 窗口截图没有重入保护（区域截图有） | 0.5s 内触发两次 → 产生无人托管的标注窗 |

另有 **2 条我一开始怀疑、但被实测证伪**的假设，一并记录在 §4，避免后续重复排查。

> **状态更新**：上表 10 条**已全部修复**，探针由 `BUG=10` 转为 **`BUG=0`**（PASS=14）。
> 逐条修法与验证见 **§7 修复记录**。唯一有意保留的是 P3-3（ScreenCaptureKit 迁移，建议单独立项）。

---

## 1. 复核方法与可复现性

新增探针 `probes/probe_post_fix_audit.swift`，已注册进 `probes/run_all.sh`：

```bash
./probes/run_all.sh post_fix        # 只跑本轮新增的复核探针
./probes/run_all.sh                 # 全套
```

设计原则：**全部黑盒**。不读 `AnnotationView` 的任何私有字段，只用：

| 手段 | 用途 |
|------|------|
| `probes/CanvasSupport.swift` 的真实 `NSEvent` | 驱动 mouseDown/Dragged/Up/keyDown 走生产代码 |
| `selects(view, at:)`（ESC + 单击 → 看 `selectedKey`） | 探测 Layer B 的**可命中区域** |
| `compositeImage()` → `NSBitmapImageRep` 逐像素 | 验证导出图内容 |
| `bitmapImageRepForCachingDisplay` + `cacheDisplay` | 离屏渲染视图，验证屏幕上的观感 |
| 40 万次采样的椭圆周长暴力搜索 | 几何真值参照 |

**探针本身也被怀疑**：第一版 `NEW-C` 的箭头起点 `(290,200)` 落在矩形 Layer B 的命中带内
（线宽 15+6 的一半 = 10.5pt），`mouseDown` 命中了矩形 → 整组用例实际在"拖动矩形"而不是"画箭头"，
于是对照组 `NEW-C0` 失败。补齐 `NEW-C0/C1` 对照组后重测，才确认 C2/C3 是真缺陷。
**没有对照组的失败用例不可信** —— 这是本轮的一条经验。

---

## 2. 缺陷清单

### P0-1 聚光灯的编辑器虚线边框仍被渲染进导出图

**这是上一轮 `CODE_REVIEW_ROUND1.md` 的 P0-2，从未落地。**

**位置**
- `Sources/Models.swift:1058-1071` — `SpotlightShape.draw` **无条件**描出 `[6,3]` 黄色虚线边框
- `Sources/AnnotationView.swift:1178-1190` — `render(into:)`（导出用）与 `draw(_:)`（屏幕用）
  调用的是**同一个** `obj.draw(in: ctx)`
- `Sources/Models.swift:273` — 协议只有 `func draw(in ctx: CGContext)`，**没有** `forExport` 之类的参数

全仓库 grep `forExport|isExporting|exporting` → **零命中**。

**证据**（探针 `NEW-A`）

```
含聚光灯的导出图有 3340 个黄色像素（示例 rgb(0.88,0.72,0.09) @(215,158)）；
同尺寸空画布为 0 个
```

3340 与"周长 640pt × 线宽 2pt × 2x × 虚线占空比 2/3"的估算（≈3400px）吻合。

**建议**（任选其一，推荐第 1 种）
1. 协议加 `func draw(in ctx: CGContext, forExport: Bool)`，`SpotlightShape` 在 `forExport` 时只画遮罩不描边；
2. 或给 `SpotlightShape` 加 `var showsBorder: Bool`，`render(into:)` 前临时置 false；
3. 或导出时对 `SpotlightShape` 走单独分支，只调用遮罩绘制。

注意：`AnnotationView.render` 里已经正确调用 `drawSpotlightOverlay(in: ctx)`（遮罩部分是对的），
要修掉的只是 `SpotlightShape.draw` 里那 2pt 的虚线描边。

---

### P0-2 程序化关窗后 `activationPolicy` 残留 `.regular` → Dock 图标永久残留

**位置**
- `Sources/AppDelegate.swift:143-150` — `closeAnnotationIfNeeded()`：为了不再弹一次确认框，
  **显式把 `window.delegate = nil` 再 `close()`**
- `Sources/AnnotationWindow.swift:605-608` — 恢复 `.accessory` 的唯一入口是 `windowWillClose`
- `Sources/AnnotationWindow.swift:240` — `setupMainMenu()` 里 `NSApp.setActivationPolicy(.regular)`

delegate 被置空 → `windowWillClose` 不会触发 → 策略停在 `.regular`。

**证据**（探针 `NEW-I`）

```
开窗后 .regular(rawValue 0) → 程序化关窗后 .regular(rawValue 0)
对照：正常关窗则为 .accessory(rawValue 1)
```

**为什么后果是"永久"**：`closeAnnotationIfNeeded()` 只在**开始新截图前**调用。之后：

| 后续路径 | 结果 |
|---------|------|
| 区域截图按 ESC 取消 | `completionHandler(nil)` → 不开新窗 → **策略永远是 `.regular`** |
| 窗口截图没找到窗口 | `showCaptureFailureAlert()` → 不开新窗 → **同上** |
| 权限不足 | `showPermissionAlert()` 提前 return → **同上** |

只有"成功打开新标注窗"这一条路径会重新 setActivationPolicy（而它本来就是 `.regular`），
所以**没有任何路径能把策略改回 `.accessory`**。表现就是 Dock 图标与菜单栏永久残留，
与 `Info.plist` 的 `LSUIElement=true` 及设计文档 §11 矛盾。

**建议**
1. 在 `closeAnnotationIfNeeded()` 里 close 之后直接补 `NSApp.setActivationPolicy(.accessory)`；或
2. 不要置空 delegate，改为给 `AnnotationWindow` 一个 `var skipsCloseConfirmation = false` 标志，
   让 `windowShouldClose` 据此跳过确认框 —— 这样 `windowWillClose` 仍会正常跑。

---

### P0-3 亚像素拖拽摧毁箭头附着，且不留任何撤销记录

**位置**
- `Sources/AnnotationView.swift:298-301` — `.moving` 分支**无条件**清空箭头附着：
  ```swift
  if let arrow = obj as? Arrow {
      arrow.startAttachment = nil
      arrow.endAttachment = nil
  }
  ```
  只要发生**一次** `mouseDragged` 就执行，与位移大小无关。
- `Sources/AnnotationView.swift:465` — `mouseUp` 只在总位移 **严格大于 0.5pt** 时才记账：
  ```swift
  if abs(totalDelta.dx) > 0.5 || abs(totalDelta.dy) > 0.5 {
      undoStack.append(.move(..., detached: pendingDetach))
  }
  ```

于是在 `总位移 ≤ 0.5pt` 时：**附着已被清空，但什么都没入栈** → 连 Cmd+Z 都救不回来。

**为什么在 Retina 上很容易撞到**：2x 屏上 1 个物理像素 = 0.5pt，
`abs(0.5) > 0.5` 为 **false** → 不记账。也就是说"点一下箭头时手抖了一个像素"就会中招。

**证据**（探针 `NEW-C`，含对照组）

```
[NEW-C0 PASS] 完全不拖，只移动父矩形：箭头端点到 (600,200)，探针 (500,200) 命中  ← 对照组
[NEW-C1 PASS] 拖 1.0pt：留下了 undo，撤销后箭头仍在                              ← 对照组
[NEW-C2 FAIL] 拖 0.5pt 后按 Cmd+Z → 箭头消失
              （撤销掉的是更早的 .add，证明这次拖拽根本没入栈）
[NEW-C3 FAIL] 拖 0.5pt 后移动父矩形 → (500,200) 无命中：端点停在原处，附着已丢
```

C2 与 C1 只差 0.5pt，行为却从"可撤销"跳到"不可撤销"，是明确的分界缺陷。

**建议**
1. 把清理附着**推迟到确认这是一次真实移动之后**（即 `mouseUp` 判定 `> 0.5pt` 时再清），
   而不是在第一个 `mouseDragged` 里就清；或
2. 保留当前清理时机，但把记账阈值降为"只要发生过 `mouseDragged` 就记账"
   （用 `didDrag` 布尔量），保证"改变必有记录"这一不变量。

---

### P1-1 拖拽聚光灯时，已有聚光灯的遮罩被叠加两次

**位置**
- `Sources/AnnotationView.swift:684` — `draw(_:)` 第 2 步先画**已有**聚光灯的遮罩
- `Sources/AnnotationView.swift:842-855` — 第 4 步 `drawPreview` 为"正在拖的聚光灯"**再画一次**遮罩
- `Sources/AnnotationView.swift:930-956` — `drawSpotlightMask` 每次都铺一层 55% 黑

两个调用各铺一层 0.55 黑，白底就变成 `0.45 × 0.45 ≈ 0.20`。

**证据**（探针 `NEW-H`，离屏渲染读同一像素）

```
两灯之外同一点亮度：拖拽预览中 0.204（=0.45²），松手后成品 0.451
```

拖拽过程中整个画布（除新选区外）明显发黑，松手瞬间"变亮" —— 所见非所得。

**建议**：预览时不要重复铺底，只画"新增的那个聚光灯"的差量；或把
`drawSpotlightOverlay` 与 `drawPreview` 的聚光灯分支合并成"一次性把 已有+预览 的路径并集传进去"。

---

### P1-2 线宽滑块的每次连续回调都记一条 undo

**位置**
- `Sources/AnnotationWindow.swift:319` + `:469-474` — `NSSlider` 默认 `isContinuous = true`，
  拖动过程连续触发 action，每次都调 `restyleSelection(lineWidth:)`
- `Sources/AnnotationView.swift:63-88` — `restyleSelection` 每次变化都
  `undoStack.append(.restyle(...))`

**证据**（探针 `NEW-B`）

```
原始线宽 15.0 → 拖到 13.0 → 按 1 次 Cmd+Z 后为 11.0（应为 15.0）
```

一次用户手势（拖滑块）被拆成 N 条撤销记录，用户得按 N 次 Cmd+Z 才能回到原状。

**建议**：参考 AppKit 惯例，用 `slider.window?.firstResponder` 无关的方式做"手势级"合并：
拖动中只更新对象不记账，`mouseUp`/`NSSlider` 的结束时机（或用一个 `NSEvent` 的
`phase` 判断）记一条 `.restyle`；也可在 `restyleSelection` 里对同一对象的连续
`.restyle` 做合并（若栈顶就是同 key 的 `.restyle` 则只更新其 `newLineWidth`）。

---

### P1-3 椭圆 `nearestPerimeterPoint` 是径向投影，不是最近点

**位置**：`Sources/Models.swift:762-777`

```swift
let t = hypot(dx / radiusX, dy / radiusY)
let localNearest = CGPoint(x: center.x + dx / t, y: center.y + dy / t)
```

这是"从圆心沿查询点方向射线与椭圆的交点"。数学上它确实在椭圆上（注释里的推导没错），
**但它不是最近点**。对圆（`radiusX == radiusY`）二者等价，椭圆越扁偏差越大。

**证据**（探针 `NEW-D`，与 40 万次采样的暴力真值对比）

| 椭圆 | 返回点距查询点 | 几何真值 | 超出 |
|------|--------------|---------|------|
| rx=200 ry=10 | 89.6 | 41.3 | **+48.2 pt** |
| rx=300 ry=40 | 37.4 | 11.9 | **+25.5 pt** |
| rx=200 ry=200（圆） | 91.8 | 91.8 | −0.0 pt |

**影响**：`detectAttachment`（`AnnotationView.swift:990`）用它的返回值判断是否附着，
并把该点算成周长参数。偏心椭圆上，用户把箭头拖到形状附近时，端点会被吸到一个
**明显偏离鼠标位置**的地方 —— 偏差可达半个箭头的长度。

**建议**（按成本排序）
1. 接受近似，但把名字/注释改成 `radialProjectionOnPerimeter`，避免后续被当成"最近点"误用；
2. 用标准迭代解（牛顿法解 `f(t)=0`，3~5 次迭代即可收敛到 <0.01pt）；
3. 对本题场景更简单：既然已有 `pointOnPerimeter(at:)`，可以先粗采样 64 个点取最近，
   再在邻近区间做一次二分细化 —— 足够精确且没有数值风险。

---

### P2-1 贴纸工具在工具栏重建后被高亮成「箭头」

**位置**
- `Sources/Models.swift:232-243` — `DrawingTool.==` 把所有 `stamp` 视为同类
- `Sources/AnnotationWindow.swift:284` — `toolList.firstIndex { $0 == annotationView.currentTool } ?? 0`

`toolList` 只有 5 个按钮（箭头/矩形/圆形/椭圆/聚光）。当前工具是 `.stamp` 时
`firstIndex` 返回 `nil`，`?? 0` 回退到**箭头** → 箭头被显示为选中态。

**触发路径**：选贴纸 → 点「换色」（`cyclePalette` → `rebuildToolbar` → `createToolbar`）。
同时 `stampPopup` 也会退回显示"选择"，丢失用户的选择。

**证据**（探针 `NEW-E`）：`firstIndex { $0 == .stamp(.checkmark) } = nil → 回退到 0`

**建议**：把 `selectedToolIndex` 改成 `Int?`，为 `nil`（贴纸）时所有工具按钮都不高亮，
并让 `stampPopup.selectItem(at:)` 恢复到当前贴纸。

---

### P2-2 `isFullyTransparent` 把 1x1 不透明图判为「全透明」

**位置**
- `Sources/ScreenCapture.swift:141` — `guard w > 1, h > 1 else { return true }`
- `Sources/AppDelegate.swift:47-55` — `hasScreenCapturePermission` 的兜底探测用
  `CGRect(x: 0, y: 0, width: 1, height: 1)` 截图，再取反

在 1x 屏上，1pt × 1pt 的探测图就是 1×1 像素 → 命中 `guard` → 返回 `true`（"全透明"）
→ `hasScreenCapturePermission` 恒为 `false`。

**证据**（探针 `NEW-F`）：1x1 不透明白图 → `isFullyTransparent = true`

**影响面有限但确实是缺陷**：`CGPreflightScreenCaptureAccess()` 先返回时不受影响；
问题出在它假阴性（代码注释里明确说这是加兜底的原因）**且**用户在 1x 屏上时 ——
此时应用会一直弹"需要屏幕录制权限"，怎么授权都没用。

**建议**：探测区域改成 `2x2`（或按 `NSScreen` 的 `backingScaleFactor` 取大一点），
并让 `isFullyTransparent` 对 `w==1 && h==1` 按像素真实 alpha 判断而非直接 `true`。

---

### P2-3 `hasEdits` 只看撤销栈，不看画布结果

**位置**：`Sources/AnnotationView.swift:123` — `var hasEdits: Bool { !undoStack.isEmpty }`

用于 `AnnotationWindow.hasUnsavedWork` → `confirmDiscardIfNeeded()`（关窗 / 重新截图前确认）。

**证据**（探针 `NEW-G`）：画出矩形后 `hasEdits=true`；把矩形删掉、画布与原图完全一致，
`hasEdits` **仍为 true** → 关闭时弹无谓的「放弃当前标注？」。

同源问题：**导出成功后 `hasEdits` 也不会清零**，所以"刚保存完就关窗"同样会多问一次。

**建议**：`hasEdits` 改为比较当前画布与初始状态（例如 `!objects.isEmpty`，
或维护一个 `didExportSinceLastEdit` 标志在导出后清零）。

---

### P3-1 窗口截图缺少重入保护

**位置**：`Sources/AppDelegate.swift:118-134`

```swift
guard closeAnnotationIfNeeded() else { return }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ... openAnnotationWindow(with: result) ... }
```

延迟块没有"是否已有待执行的截图"标志，也没有 `regionSelectionWindow` 那样的清理。
0.5s 内触发两次 → 两个块都执行 → `openAnnotationWindow` 调两次 →
`annotationWindow` 被第二次覆盖，**第一个标注窗仍留在屏幕上但应用已不再持有它**
（`closeAnnotationIfNeeded` 找不到它，其编辑也无法确认/丢弃）。

对比：区域截图的同类问题（上一轮 P2-7）**已经修好**（`AppDelegate.swift:104-105`
先 `cancelSelection()` 再置 nil），窗口截图这条路径漏了。

**建议**：加 `private var pendingWindowCapture = false` 做互斥；或在
`startWindowCapture` 开头先取消上一次待执行的块（保存 `DispatchWorkItem` 并 `cancel()`）。

---

### P3-2 `captureRegion` 回退路径的注释与调用方不符

**位置**
- `Sources/ScreenCapture.swift:134-135` — 回退注释："此时需调用方保证覆盖层已经隐藏"
- `Sources/RegionSelectionWindow.swift:105-107` — 调用方**先截图、后** `teardown()`

回退用 `kCGNullWindowID`（= 不排除任何窗口），而覆盖层此时仍在屏幕上。
实测影响很小：选区内部已被 `.clear` 挖空，所以拍到的内容基本正确，
只有描边线宽的内半边（0.75pt）会作为白虚线出现在图像四边。

**建议**：要么把 `teardown()` 提到 `captureRegion` 之前（当前不需要"隐藏再 sleep"，
因为主路径用 `belowWindow`，改顺序不影响主路径），要么把注释改成与事实一致的说明。

---

### P3-3 仍未修复：`CGWindowListCreateImage` 锁死部署目标（上一轮 P0-1）

仓库自带探针复跑结果：

```
[PASS] macOS 13.0 编译干净        [INFO] macOS 14.0 编译通过但有 6 条弃用警告
[FAIL] macOS 15.0 编译失败：'CGWindowListCreateImage' is unavailable in macOS
```

`SCREEN_CAPTURE_OBSOLETE(10.5, 14.0, 15.0)` —— 该 API 在 macOS 15 起不可用，
因此 `Package.swift` 的 `.macOS(.v13)` 是目前唯一能通过编译的选择，
无法提高部署目标、也无法走正常公证分发。上一轮已把它列为"可单独立项"，
本轮确认**它仍然是唯一的架构级未决项**。

---

### P3-4 仓库卫生：失效的自动提交脚本仍在版本控制里

`.qoder/auto_git_push.sh` 是一个 `while true; sleep 600` 的自动 `git add -A` + commit + push 脚本。
它写死的 `REPO_DIR=/Users/fengyong/qoder/ai-snap` **已不存在**（仓库现在在 `/Users/ola/fengyong/ai-snap`），
它会 `cd` 失败后 `exit 1`；日志停在 `2026-04-04 09:49:50`，确认早已失效。

目前无害，但它是"每 10 分钟把工作区一切改动提交并推送"的行为，一旦路径被重建就会突然生效。
建议删除该文件（及其日志），或明确改为手动触发的脚本。

---

## 3. 复核确认成立的部分

上一轮 24 项修复的结论**经得起复跑**。`./probes/run_all.sh` 全量结果：

```
probe_deployment_target.sh     复现缺陷数 = 1   ← 即上文 P3-3（已知未修）
probe_layout                   复现缺陷数 = 0
probe_geometry                 复现缺陷数 = 0
probe_canvas                   复现缺陷数 = 0
probe_spotlight                复现缺陷数 = 0
probe_perf                     复现缺陷数 = 0
probe_export_scale             复现缺陷数 = 0
probe_watermark                复现缺陷数 = 0
probe_screens                  复现缺陷数 = 0
probe_region                   复现缺陷数 = 0
probe_signing.sh               复现缺陷数 = 0
render_arrows                  复现缺陷数 = 0
probe_colors                   复现缺陷数 = 0
```

另外，本轮的 Layer B 逐点扫描（ASCII 命中图）确认**命中检测层的几何是精确对齐的**：

- 矩形 `(200,100)-(400,200)` 的命中带正好是 ±10.5pt（线宽 15+6 的一半），四边完整；
- 箭头 `(150,150)→(450,150)` 的命中带是连续的 `x∈[150,450], y∈[140,160]`，无断点；
- 多显示器坐标换算（`primaryDisplayHeight` 锚定 `frame.origin == .zero` 的那块屏）
  与 Quartz 约定一致 —— 上一轮对 `NSScreen.main` 语义的修正是正确的。

---

## 4. 被实测证伪的假设（诚实记录）

为了避免后续重复排查，把我一开始怀疑但**证据不支持**的两条也记下来：

| 假设 | 实测结果 | 结论 |
|------|---------|------|
| 虚线/点线箭头的线型被带进 Layer B，导致命中区被打断 | 沿箭杆每 2pt 采样：实心 100% / 虚线 100% / 点菱 100% | **不成立**。`setLineCap(.round)` 使 2~8pt 的点划被端帽各外扩 `lw/2`，在 21pt 的命中线宽下相邻点划完全重叠 |
| 默认线宽 15 下线型被端帽填平，"虚线"与"实心"渲染相同 | 线宽 15 与线宽 3 下，两者渲染结果**均逐字节不同** | **不成立**。线型在屏幕上是可区分的 |

这两条已作为 `NEW-J` / `NEW-K` 的 `[PASS]` 用例固定在探针里，作为回归保护。

---

## 5. 建议修复顺序

```
1. P0-3  亚像素拖拽摧毁附着      —— 唯一的"不可恢复数据丢失"，改动最小（1 个 if 的位置）
2. P0-2  activationPolicy 残留    —— 用户可见的"应用卡在 Dock 上不走"，1 行可修
3. P0-1  聚光灯边框进导出         —— 上一轮承诺未兑现，影响每一张带聚光灯的导出图
4. P1-1  聚光灯预览双重压暗       —— 视觉明显，改动局部
5. P1-2  滑块 undo 合并           —— 交互手感，涉及一次手势边界
6. P1-3  椭圆最近点               —— 影响吸附落点精度，建议先改注释再用迭代解
7. P2-1 ~ P2-3                    —— 显示/判定类小缺陷，可一并处理
8. P3-1 / P3-2                    —— 健壮性收口
9. P3-3  ScreenCaptureKit 迁移    —— 独立立项（架构级）
10. P3-4 清理失效脚本             —— 顺手
```

其中 **P0-2、P0-3、P2-1、P2-2、P2-3、P3-1** 都是"判断条件/时序差一点"的局部问题，
不建议为它们改动架构；**P0-1** 需要给协议加导出态参数，是本轮唯一有设计含义的修改。

---

## 6. 附录：本轮探针清单

`probes/probe_post_fix_audit.swift`（已注册进 `run_all.sh`）

| 编号 | 断言 | 结果 |
|------|------|------|
| NEW-A | 聚光灯编辑器边框不进导出图 | FAIL（3340 黄像素） |
| NEW-B | 一次滑块拖拽可被一次撤销 | FAIL（15→13，撤销后 11） |
| NEW-C0 | 附着的箭头跟随父形状（对照组） | PASS |
| NEW-C1 | 1.0pt 拖拽会记账且可撤销（对照组） | PASS |
| NEW-C2 | 0.5pt 拖拽也应可撤销 | FAIL |
| NEW-C3 | 0.5pt 拖拽后附着仍在 | FAIL |
| NEW-D | 椭圆最近点误差 < 1pt | FAIL（最差 48.2pt） |
| NEW-E | 贴纸工具能定位到工具栏按钮 | FAIL |
| NEW-F | 1x1 不透明图不被判为全透明 | FAIL |
| NEW-G | 画布清空后 `hasEdits` 为 false | FAIL |
| NEW-H | 聚光灯预览亮度 == 成品亮度 | FAIL（0.204 vs 0.451） |
| NEW-I | 程序化关窗后回到 `.accessory` | FAIL |
| NEW-J | 各种线型的命中率一致 | PASS（证伪假设） |
| NEW-K | 默认线宽下线型可区分 | PASS（证伪假设） |

```
========== probe_post_fix_audit: PASS=14  BUG=0  INFO=3 ==========
```

---

## 7. 修复记录（§2 全部 10 条已落地）

复跑 `./probes/run_all.sh post_fix` → **PASS=14 / BUG=0**。

| 编号 | 修复位置 | 修法 |
|------|---------|------|
| P0-1 聚光灯边框进导出 | `Models.swift` 协议 + `SpotlightShape` | 协议新增 `drawForExport(in:)`（默认转调 `draw`），`SpotlightShape` 覆写为空 —— 导出只留遮罩。`AnnotationView.render` 改调 `drawForExport` |
| P0-2 激活策略残留 | `AnnotationWindow.close()` | 把恢复 `.accessory` 从 `windowWillClose` 挪进 **覆写的 `close()`**，覆盖包括"delegate 被置空"在内的所有关窗路径 |
| P0-3 亚像素拖拽摧毁附着 | `AnnotationView.mouseDragged/mouseUp` | 解除附着**推迟到 mouseUp 确认是真实移动时**；`totalDelta ≤ 0.5pt` 则把位移整体回退并恢复附着，维持"没记录 ⇔ 没变化"。`.rotating/.scaling` 同样处理 |
| P1-1 聚光灯预览双重压暗 | `AnnotationView.draw/drawPreview` | 遮罩只在 `drawSpotlightOverlay(includingPreview:)` 铺一次；拖拽中的路径并入同一批。`drawPreview` 只补边框 |
| P1-2 滑块 undo 刷屏 | `AnnotationWindow` + `AnnotationView` | 新增 `GestureReportingSlider` 上报松手；拖动中走 `previewSelectionLineWidth`（不记账），松手由 `commitSelectionLineWidth(from:)` 记**一条**。键盘/程序化通路也直接落账 |
| P1-3 椭圆最近点 | `Models.swift` | 径向投影换成 **64 等分粗扫 + 黄金分割细化**，实测误差 0.000pt（旧实现最差 48.2pt） |
| P2-1 贴纸高亮错位 | `AnnotationWindow.createToolbar` | `firstIndex` 找不到时用 `?? -1`（不再回退到「箭头」）；并按当前贴纸 `selectItem(at:)` 同步下拉框 |
| P2-2 1x1 判为全透明 | `ScreenCapture.isFullyTransparent` | `guard w > 1, h > 1` → `guard w > 0, h > 0`，1×1 也走真实像素判定 |
| P2-3 hasEdits 语义 | `AnnotationView` | 改为 `!objects.isEmpty && contentVersion != exportedVersion`：画完又删光、以及刚导出未再改，都不再误报 |
| P3-1 窗口截图重入 | `AppDelegate.startWindowCapture` | 用 `DispatchWorkItem` 持有待执行任务，重入时先 `cancel()` |
| P3-2 回退路径拍到覆盖层 | `RegionSelectionWindow.finishSelection` | 主路径失败时**先 `teardown()` 再回退**；`teardown()` 改为幂等（避免重复 `NSCursor.pop()` 造成 push/pop 失衡） |

### 修复过程中发现的两个附带问题

1. **`restyleSelection(lineWidth:)` 被架空了**。改成"预览 + 提交"两段式之后，这个方法不再有生产调用点。
   它保留下来供 `probe_colors` 等外部驱动使用，但真正改线宽的通路已经不走它。
2. **`.rotating` / `.scaling` 有和 P0-3 同源的缺陷**：低于记账阈值时同样"改了但不记录"。
   报告初次只列了 `.moving`，修复时把这三条统一成同一个不变量。

### 未修（有意保留）

| 项 | 原因 |
|----|------|
| P3-3 `CGWindowListCreateImage` → ScreenCaptureKit | 架构级改造：要换异步截图管线、提高部署目标到 macOS 15，且需要真机验证多屏/窗口/权限三条路径。**建议单独立项**，不适合混在本次修复里 |
| P3-4 `.qoder/auto_git_push.sh` | 删除一个已被跟踪的文件属于破坏性操作，等你确认再动 |

### 探针断言的自我修正（重要）

修复后有两条断言反而"失败"了，**是断言本身写错了**，不是实现回退：

- `NEW-C2` 原来用"按一次 Cmd+Z 看箭头还在不在"判断"有没有记账"。修复后正确行为是
  **这次拖拽被当成无操作**，于是栈顶仍是更早的 `.add`，撤销后箭头照样消失 ——
  修复前后在这个断言上表现相同，它**不具备区分能力**。改成直接测"附着有没有被摧毁"（真正的损害面）。
- `NEW-E` 原来在探针里复刻了旧实现的一行逻辑（`firstIndex ?? 0`）来断言。
  修复的正确形态不是"让 firstIndex 能找到贴纸"，而是"找不到时不回退 + 同步下拉框"。
  改成实例化真实 `AnnotationWindow`、点「换色」触发工具栏重建，再检查按钮高亮与下拉框选中项。

教训与 §1 一致：**断言必须锚在用户可观察的后果上，而不是复刻实现细节**，
否则修好之后断言会拦住的恰恰是正确的实现。

