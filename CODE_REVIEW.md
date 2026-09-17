# AISnap 代码 Review 报告

审查范围：`Sources/` 全部 8 个文件（3164 行）、`Package.swift`、`build.sh`、`README.md`、`DESIGN.md`、git 仓库状态。
审查方式：逐行阅读 + 可复现的实验验证（编译、独立 harness、微基准、像素级回归），不依赖推测。

---

## 0. 结论摘要

架构是成立的：双图层 Color Picking 命中检测、`AnnotationObject` 协议抽象、撤销/重做状态机都经得起实测（见 §7）。代码组织清晰、无第三方依赖、无内存/线程安全问题（全部在主线程，无共享可变状态竞争）。

但存在 **2 个阻断级问题**、**12 个功能性缺陷（P1-1 ~ P1-12）**，其中大部分在你这台 3 屏 Mac 上是可以立刻复现的：

| 级别 | 问题 | 影响面 |
|------|------|--------|
| P0 | `CGWindowListCreateImage` 在 macOS 15 已被 obsolete，项目被锁死在 macOS 13 部署目标 | 无法升级部署目标/无法公证分发 |
| P0 | 工具栏排版溢出：窄截图下「保存/复制/帮助」按钮跑到窗口外 | 默认配置下小截图既点不到也 Tab 不到「保存」 |
| P1 | 窗口截图 Y 轴翻转参照错误（实测偏差 72pt） | 多显示器下抓错窗口 |
| P1 | 副屏区域截图完全不可用（覆盖窗口吞掉点击） | 3 屏环境下 2 块屏不能用 |
| P1 | 标注窗口的位置/缩放取自 `NSScreen.main`，而它不是"截图来源屏" | 可能弹到与截图无关的显示器上 |
| P1 | 多个聚光灯重叠处被重新压暗（README 宣称支持叠加） | 实测重叠区亮度 0.574 vs 单区 1.000 |
| P1 | Layer B 调试面板让拖拽每帧耗时约 25–27ms（关闭时约 0.2ms） | 拖拽卡顿，上限约 37–40 次/秒 |
| P1 | 选中对象后，Option/Shift 拖拽画布**任意位置**都会旋转/缩放它 | 误操作 |
| P1 | 移动箭头会永久解除附着，且撤销无法恢复 | 标注关系丢失 |
| P1 | **箭头永远无法附着到圆/椭圆**（`nearestPerimeterPoint` 数学错误，实测偏差 9900px） | 画圈+箭头指过去的核心用法失效 |
| P1 | **旋转/缩放父形状时，附着的箭头不跟随**（只有"移动"是对的） | 实测箭头停留在原位，视觉脱节 |
| P1 | **窗口截图的窗口挑选没有任何过滤条件**（layer/alpha/尺寸），且命中不可截窗口时**静默无反应** | 实测选到 Window Server 窗口 → 截图为 nil → 点了菜单毫无动静 |
| P1 | **副屏选区坐标换算漏掉屏幕原点**（实测偏差 (803,-910)pt） | 截到的是另一块屏上的区域 |
| P1 | **`NSScreen.main` 被当成坐标锚点**（CG 的 "main display" 是另一回事） | 上面 P1-1/P1-3 的共同根因 |
| P4 | 切换调色板（4 色→5 色）后色板压住后面的控件（第 19 条） | 实测重叠 12pt |
| P4 | 标注过程中再次触发截图会**无确认地丢弃**当前全部标注（第 20 条） | `annotationWindow?.close()` 无提示 |

---

## 0.1 三轮 review 的复核结论（第二轮找漏、第三轮自我证伪）

第一轮报告完成后，又做了两轮：

* **第二轮（找漏）**：换角度重读 + 用真实 `NSApp.run()` 会话验证。新增 2 条（P4-19 切色板压控件、P4-20 再次截图无确认丢弃标注）；
  并证伪了一条自己一度怀疑的结论（见下）。
* **第三轮（证伪）**：对第一轮里**由子代理给出或靠推理得出、我本人没有亲手复现**的结论逐条重做实验。
  结果是：4 条得到独立确认，3 条被修正（措辞过强或机制描述错误），1 条降级为"风险"。
* 同时把全部结论固化成了可执行探针：`probes/`（见 §9）。**当前 11 个探针合计复现 25 条缺陷。**

### 被修正的结论（重要）

| 条目 | 第一轮的说法 | 复核后的准确说法 |
|------|--------------|------------------|
| **P0-2** | 窄截图"**完全无法保存**" | 按钮确实被排在窗口外（鼠标点不到、看不见），且没有 Cmd+S；但它仍在 key view loop 中，本机 `AppleKeyboardUIMode` 未设置（=0，全键盘控制关闭）所以 **Tab 默认够不到**。结论仍然成立，但"完全无解"应表述为"默认配置下鼠标与键盘都够不到" |
| **P1-12** | `NSScreen.main`"**跟着鼠标走**" | **机制不成立**：实测鼠标在 (0,1080)（主屏）时 `NSScreen.main` 仍返回第三块屏，并不随鼠标。可靠的说法是 SDK 注释：`NSScreen.mainScreen` = "Screen with key window"，它**在语义上就不是坐标锚点**，实测也确实 ≠ 主显示器。原先那句"5/5 跟随鼠标"来自子代理，我的数据不支持，已删除 |
| **P1-3** | 标注窗口"**会弹到别的显示器上**" | 过度断言。正常流程里用户是点菜单栏（在主屏）触发截图的，此时 `NSScreen.main` 有可能正好是主屏。准确说法：**代码用 `NSScreen.main` 决定窗口的位置与缩放，而该值在无 key window 时不是"截图来源屏"**——本机实测它落在第三块屏；请用探针在正常会话下确认影响面 |
| **P2-5** | `CGPreflightScreenCaptureAccess()` "**会**返回假阴性，把用户卡死" | 降级为**风险**：唯一依据 preflight 确实是脆弱设计（社区有大量假阴性报告），但**我无法在本机按需复现**。真实缺陷是两条可验证的：① 授权后运行中的进程不会重新检测；② 完全不校验截图结果（越界/无权限都会返回合法图片，见探针 P2-6b） |
| **P1-11** | 数据引自子代理，我未复现 | **已亲手复现**（探针 `probe_region`）：目标屏 1512×982@(-803,-982)，视图内选区 (756,491,200,150) → 代码算出 `(756,511)`，正确值 `(-47,1421)`，**偏差 (803,-910) pt**，两次截图内容不同 |
| **P3-3** | 签名问题引自子代理 | **已亲手复现**：`codesign -dvvv` 输出 `flags=0x20002(adhoc,linker-signed)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Info.plist=not bound` |
| **P1-1** | 72pt 偏差 | 偏差已复现，并**用 `CGEvent(source: nil).location` 反证**：代码的换算结果与它相差 **0 pt**，而用 `NSScreen.main` 的锚点差 72pt —— 证明正确锚点就是主显示器高度 |
| **§7 命中/撤销基线** | 我先前的手写 harness 结论 | 已固化为探针：`HIT-1..6` 全 PASS、`UNDO-1/2`（9 步混合操作像素级往返）全 PASS |

### 被证伪的一条（第一轮之后新产生的怀疑）

一度怀疑"ESC 取消选中无效"——因为 `AnnotationView.mouseDown` 没有任何 `makeFirstResponder`。
用真实 `NSApp.run()` 会话验证后**证伪**：AppKit 会把 `AnnotationView` 自动设为窗口的 first responder
（实测 `window.firstResponder is AnnotationView == true`，且它就在响应链上），ESC 能正常到达
`keyDown`。**这一条没有写进报告**。

### 关于会话状态的诚实说明

本机在被审查时处于**锁屏/无人操作**状态，可从窗口列表里出现 `loginwindow`、鼠标坐标被钉在
(0,1080)、`NSApp.isActive` 恒为 false 看出。因此：

* P0-1 / P0-2 / P1-4~P1-9 / P2-1 / P2-3 / P2-4 / P3-* 的结论**与会话无关**，可直接采信；
* P1-1 / P1-2 / P1-3 / P1-10 / P1-12 的**代码缺陷**由 SDK 文档即可判定（已逐条引用头文件注释），
  但**具体数值**（偏移 72pt、挑中 Window Server 窗口）带锁屏污染，请用 `probes/` 在解锁会话下复跑一次。

## 0.2 报告自身的准确性审计（第三轮追加）

对这份报告做了一次逐条核对，**发现并修掉了 16 处不准确**。列出来是因为"报告本身可信"也是结论的一部分：

| # | 问题 | 处理 |
|---|------|------|
| 1 | §0 摘要写"10 个功能性缺陷"，实际有 **12** 条（P1-1 ~ P1-12） | 改为 12 |
| 2 | §0 摘要仍写着"小截图**完全无法保存**"、"标注窗口**弹到别的显示器**"——这两句在 §0.1 已经被我自己修正过，摘要没同步 | 摘要改为修正后的措辞 |
| 3 | §0 摘要表**漏了 P1-11、P1-12** 两行 | 补齐 |
| 4 | §1 表格里仍写着 `NSScreen.main`"返回**鼠标所在屏**（5/5）"——这正是 §0.1 已作废的说法，**前后矛盾** | 改为"实测 ≠ 主显示器"，并显式标注该机制说法已作废 |
| 5 | §1"命中检测 20/20 通过"是一次性 harness 的遗留数字，无法复跑 | 换成探针编号（`HIT-1..6`，6/6） |
| 6 | §1 性能数字（0.2 / 26.9ms，60 次迭代）与探针（0.17 / 24.7ms）不一致 | 统一为探针实测值 |
| 7 | §1"导出分辨率"一行描述的是另一个测量（600×400pt→1200×800px），与探针 A 场景不同 | 统一为探针数据 |
| 8 | P1-11 的偏差向量**符号写反**：`(-2048, +360)` 应为 `(+2048, +360)` | 改用我自己探针可复跑的数据 `(+803, -910)` |
| 9 | P1-10 把"列表按 layer 降序"当成文档行为 | 改为"SDK 只承诺 front-to-back，实测层级高的在前" |
| 10 | P1-1 里"鼠标在主屏底部 60pt 处"读起来像实测 | 明确标注为算术示例 |
| 11 | §6 第 16 条对"旧覆盖窗口残留"只有推理，且定性为"资源泄漏" | **实测确认**（在屏窗口 3 → 6），并修正机制（`NSApplication.windows` 持有窗口，ARC 释放 ≠ 关闭）与定性（是**状态污染**：旧层仍可交互、会把新窗口引用置 nil） |
| 12 | §7 第 12 条把"覆盖窗口几何正确"列为优点，容易被误读成"副屏可用" | 加注说明这只说明窗口摆对了 |
| 13 | §7 第 14 条引用子代理的"63/63 个窗口"精确计数，我本人没数过 | 改为我实际验证到的范围 |
| 14 | §7 第 15 条声称"在 macOS 15/26 上仍能运行"但没给证据 | 补上本机（macOS 26.5.1）探针的实际调用结果 |
| 15 | 探针编号 `P4-12/P4-13` 与报告 P4 清单的第 13/14 条**对不上** | 探针改为 `P4-13/P4-14`，与报告编号对齐 |
| 16 | §0.1 之后多了一条重复的 `---` 分隔线 | 删除 |

另外复核了报告里的统计数字，全部与仓库当前状态一致：源文件 3164 行、受控文件 2438 个（`.build/` 占 2409）、`.git` 93MB、`.build` 575MB、P4 清单 20 条。

**仍然存疑、需要你在真实会话里确认的**（我无法在锁屏环境下定论）：
P1-1 / P1-2 / P1-3 / P1-10 / P1-12 的**具体数值与影响面** —— 代码缺陷本身由 SDK 文档支撑，但这几条的"实际有多严重"请在解锁会话下用 `probes/` 复跑。

---

## 0.3 每条结论的证据等级

避免"一视同仁地相信"，这里把证据强度分三级列清楚：

| 等级 | 含义 | 覆盖的条目 |
|------|------|-----------|
| **A 探针可复跑** | `./probes/run_all.sh` 能直接复现，换台机器也能验证 | P0-1、P0-2、P1-4、P1-5、P1-6、P1-7、P1-8、P1-9、P2-1、P2-6、P3-3、P4-14、P4-19；§7 的第 1、2、4、5、6、10、14、15 条 |
| **B 源码/文档/一条命令即可判定** | 读对应源码或 SDK 头文件注释、或跑一条 CLI 就能确认，不需要 GUI 会话 | P1-10 的"缺少 layer/alpha/尺寸过滤"、P1-12 的 `NSScreen.main` 语义、P2-2、P2-3、P2-4、P2-7、P3-1、P3-2、P3-4、P3-5、P4-1~P4-11、P4-15~P4-18、P4-20；§7 的第 7、8、9、11、13 条 |
| **C 缺陷确定、但严重程度随会话变化** | 我在**锁屏会话**下测的，请解锁后复跑再定优先级 | P1-1、P1-2、P1-3、P1-11、P1-12 的实测数值、P1-10 的"实际选中哪个窗口"、P2-5（只有社区证据，无法按需复现假阴性） |

**另有一条需要单独标注**：P4 第 12 条（`snapPoints()` 顺序确定、附着索引在移动/旋转/缩放后仍指向同一几何特征）与第 13 条（`computePerimeterParameter` 与 `pointOnPerimeter` 互为逆函数，2 万采样）的**数值论证来自独立审查分支，我没有逐条重跑**。我独立验证的只是它们的必要条件：探针 `P4-13` 确认 `pointOnPerimeter` 的采样点确实落在周长上（矩形/椭圆偏差 0.0000 px），以及探针 `P1-9a` 确认 `.snapPoint(index:)` 附着在父对象移动后仍解析到正确端点。**如果你要依赖这两条结论，建议先自己复跑一次。**

另外，§7 第 3 条（级联删除 + 撤销）由早期手写 harness 覆盖，后来并入探针的删除步骤，强度介于 A 与 B 之间。

一句话用法：**A 级直接信并复跑；B 级读一眼源码/头文件即可确认；C 级请用探针在你自己的会话里再测一次再决定优先级。**

---

## 1. 验证方法与可复现证据

| 实验 | 命令/产物 | 结论 |
|------|-----------|------|
| 编译（当前目标） | `swift build` | 通过，0 warning，0 error |
| 编译（提升部署目标） | `swiftc -typecheck -target arm64-apple-macosx{13,14,15}.0 Sources/ScreenCapture.swift` | 13.0 干净 / 14.0 弃用警告 / **15.0 硬错误** |
| 命中检测黑盒测试 | 编译真实源码 + 合成 `NSEvent` 驱动 `AnnotationView`（已固化为探针 `HIT-1..6`） | 6/6 通过（矩形描边/内部不误选、箭头、椭圆轮廓/内部不误选、贴纸） |
| 撤销重做像素级回归 | 9 步混合操作（增/移/转/缩/删/附着）全撤销再全重做，比对合成图哈希（探针 `UNDO-1/2`） | **9/9 完全一致** |
| 附着跟随 | 移动父对象后检查箭头端点 | 移动 ✓ / **旋转 ✗ / 缩放 ✗**（见 P1-9） |
| 圆/椭圆附着 | 端点精确落在椭圆轮廓上再移动椭圆 | **失败**：附着不成立（见 P1-8） |
| 聚光灯叠加 | 两个重叠聚光灯，读取合成图像素亮度 | **失败**：外区 0.450 / 单区 1.000 / 重叠区 0.574 |
| 拖拽性能 | 2560×1440 画布 + 20 对象，多次拖拽取均值 | 调试面板关约 0.17ms/事件，开约 **24.7ms/事件** |
| 整屏重绘性能 | 同一画布 `draw(bounds)` 到离屏 bitmap | 3.1ms/帧（不是瓶颈） |
| 导出分辨率 | `compositeImage()` → TIFF → 像素尺寸 | 2x 屏上等于源像素（5120×2160 px → 5120×2160 px） |
| 工具栏布局 | 实例化 `AnnotationWindow` 打印子视图 frame | 见 P0-2 |
| 窗口按键/激活 | 真实 `NSApp.run()` 循环观察 `isKeyWindow`/`firstResponder` | 见 §6 第 2 条 |
| 窗口挑选 | 复刻 `captureWindowUnderMouse` 的循环，打印列表头部与实际选中项 | **选到 Window Server 窗口，截图返回 nil**（见 P1-10） |
| 越界矩形截图 | 对屏幕外矩形调用 `captureRegion` | 返回**非 nil 的全透明图**（alpha=0），不报错 |
| `NSScreen.main` 语义 | 观察它与 `screens[0]` / `CGMainDisplayID()` 的关系 | 实测 ≠ 主显示器（见 P1-12）。**注意：它并不"跟随鼠标"——第一轮的该说法已作废** |
| 圆/椭圆附着（数学） | 直接调用 `nearestPerimeterPoint`，输入取在椭圆上 | θ=0°/45°/90° 误差分别为 9900 / 7212 / 2450 px（见 P1-8） |
| 二次触发区域截图 | 连续创建两个 `RegionSelectionWindow`，统计本进程在屏窗口数 | 旧窗口**未下屏**：3 个 → **6 个**（见 §6 第 16 条） |

> 说明：为降低漏判风险，第一轮后另派了两个独立审查分支分别复核"几何/附着数学"与"截图/权限/生命周期"；
> 随后又做了第二、三轮 review（找漏 + 自我证伪），并把全部结论固化成了 §9 的可执行探针套件。
> 子代理给出的结论**必须由我另行复现**才会写入本报告 —— 未能复现的已在 §0.1 中降级或删除。
>
> 上表每一行现在都可以用 `./probes/run_all.sh [关键字]` 复跑（见 §9），不再依赖 `/tmp` 里的临时 harness。

所有临时 harness 位于 `/tmp/aisnap-*`；可复跑的探针已随仓库提供（`probes/`，见 §9），未改动任何 `Sources/` 源码。

---

## 2. P0 — 阻断级

### P0-1 `CGWindowListCreateImage` 已被 macOS 15 obsolete，项目被锁死在 macOS 13

**位置**：`Sources/ScreenCapture.swift:40`、`:53`；约束来源于 `Package.swift:5`（`platforms: [.macOS(.v13)]`）

SDK 头文件（`CoreGraphics/CGWindow.h:271`）声明：

```c
CG_EXTERN CGImageRef __nullable CGWindowListCreateImage(...)
    SCREEN_CAPTURE_OBSOLETE(10.5,14.0,15.0);   // 10.5 引入，14.0 弃用，15.0 起不可用
```

实测：

```
-target arm64-apple-macosx13.0  → 编译干净
-target arm64-apple-macosx14.0  → warning: 'CGWindowListCreateImage' was deprecated in macOS 14.0
-target arm64-apple-macosx15.0  → error: 'CGWindowListCreateImage' is unavailable in macOS
```

**影响**：
- 现在能编译，纯粹是因为 `Package.swift` 把部署目标钉在 13.0。任何一次「顺手把 `platforms` 升到 `.v15`」都会让整个工程编译失败。
- 上架/公证/用新版 Xcode 模板重建都会撞上同一堵墙。
- 该 API 在 15.0 被标为 obsolete（而非仅 deprecated），未来系统移除它在设计意图之内 —— 截图功能是**整个应用的地基**，这是最大的技术债。

**修复**：把 `ScreenCapture` 抽象成协议，用 ScreenCaptureKit（`SCScreenshotManager.captureImage(contentFilter:configuration:)`）实现 macOS 14+ 路径，`CGWindowListCreateImage` 仅保留为 macOS 13 回退分支。这样 `platforms:` 才能安全上移。

### P0-2 工具栏溢出：窄截图下「保存/复制/帮助」在窗口之外，且窗口不可缩放

**位置**：`Sources/AnnotationWindow.swift:37-38`（窗口宽度 `max(totalWidth, 780)`）、`:294-307`（按钮宽度）、`:272-288`（导出按钮排在最后）、`:47`（styleMask **没有 `.resizable`**）

工具栏从左往右依次排布，累计需要 **916pt**（5 色板时 946pt）；而窗口宽度被钳制为 `max(图片宽*1.5+8, 780)`。

实测（本机 `NSScreen.main` = 2048×1152）：

```
源图 200x150  → 窗口宽 780   保存[792..828]  复制[830..866]  帮助[880..916]   三个按钮全部在窗口外
源图 600x400  → 窗口宽 908   保存[792..828]  复制[830..866]  帮助[880..916]   帮助被切掉 8pt
源图 2560x1440→ 窗口宽 1811  三个按钮都在窗口内
```

换算成阈值：

- 截图宽度 **< 547pt**（2x 屏约 1094px）→ **「保存」完全不可见**
- 截图宽度 **< 572pt** → 「复制」不可见
- 截图宽度 **< 606pt** → 「帮助」被裁切

**这三条逃生通道基本堵死**：窗口 `styleMask` 不含 `.resizable`（拉不宽）、没有 Cmd+S、编辑菜单里也没有保存/复制项。

探测到的唯一例外（`probe_layout` 实测）：几个按钮**仍然留在 key view loop 里**，所以理论上可以盲选到；但本机 `AppleKeyboardUIMode` 未设置（= 0，即「全键盘控制」关闭），Tab 默认不会把焦点移到按钮上，而且按钮在窗口外、聚焦了也没有任何视觉反馈。因此准确表述是：**默认配置下，500pt 宽的截图既点不到「保存」也 Tab 不到它**，用户只能重新截一张更大的。

**修复**（任选其一，建议 1+3）：
1. 窗口最小宽度改为按工具栏实际所需宽度计算（把 `createToolbar` 的累计 `xOffset` 返回出来参与取 max）；
2. 工具栏撑不下时折行或放进 `NSScrollView`；
3. 无论排版如何，都补上 `Cmd+S` / `Cmd+C` 菜单项，保证导出路径永远可达。

---

## 3. P1 — 功能性缺陷

### P1-1 窗口截图的 Y 轴翻转用错参照系（多显示器必错）

**位置**：`Sources/ScreenCapture.swift:35-37`

```swift
let screenHeight = NSScreen.main?.frame.height ?? 0
let flippedY = screenHeight - mouseLocation.y
```

`CGWindowListCopyWindowInfo` 的 bounds 用的是**主显示器左上角为原点**的全局坐标（`CGWindow.h:66` 原文：*"The bounds of the window in screen space, with the origin at the upper-left corner of the main display"*）；而 `NSEvent.mouseLocation` 用的是**主显示器左下角为原点**。所以翻转常量必须是**主显示器**（Quartz 语义：`CGMainDisplayID()`，即菜单栏所在屏）的高度。

这里有个术语陷阱：**Core Graphics 的 "main display" ≠ `NSScreen.main`**。后者的 SDK 注释只有一句 *"Screen with key window"*（`NSScreen.h`），窗口焦点在哪块屏它就是哪块 —— 代码正好踩了这个同名不同义的坑。

**反证**：用 `CGEvent(source: nil).location`（它本来就在 Quartz 坐标系里，无需翻转）对照 —— 用主显示器高度换算的结果与它**偏差 0 pt**，用 `NSScreen.main` 的锚点则差 72 pt（`probe_screens` 实测）。

本机实测：

```
CGDisplayBounds(CGMainDisplayID()) = (0, 0, 2560, 1080)   ← 正确参照，高度 1080
NSScreen.screens[0].frame          = (0, 0, 2560, 1080)
NSScreen.main?.frame               = (-2048, 288, 2048, 1152)  ← 代码用的，高度 1152
```

→ 锚点差 **72pt**（本例中，只要 `NSScreen.main` 停在第三块屏上，这个偏移就是恒定的）。举个算术例子：若鼠标在主屏底部往上 60pt（`NSEvent` 的 y = 60），正确测试点是 `y = 1080 - 60 = 1020`，而代码算出 `1152 - 60 = 1092`，相差 72。命中判定 `bounds.contains(testPoint)` 因此会落到错误的窗口上，或落进窗口之间的空隙导致「窗口截图没反应」。

**修复**：改用 `CGDisplayBounds(CGMainDisplayID()).height`，或更彻底 —— 直接用 `CGEvent(source: nil)?.location`（它本来就是左上角原点的全局坐标），彻底不做翻转。

### P1-2 副屏区域截图完全不可用

**位置**：`Sources/RegionSelectionWindow.swift:38-50`（副屏覆盖窗口）、`:61-82`（`finishSelection` 用 `NSScreen.main?.frame` 换算）、`:98-127`（只有主屏的 view 处理鼠标）

副屏的 `overlayWindows` 只设置了 level/背景/`hasShadow`，**没有 contentView、没有 `RegionSelectionView`、没有 `ignoresMouseEvents = true`**。实测其属性：

```
overlay.contentView        = NSView      ← AppKit 自动补的空 content view
overlay.ignoresMouseEvents = false       ← 会吞掉鼠标事件
overlay.canBecomeKey       = false
```

因此在副屏上按下鼠标时，事件被这块空窗口吃掉，主选区窗口收不到任何东西：**既不开始选择，也不报错，ESC 之外的任何操作都没有反馈**。即便事件能传过去，`finishSelection` 里的坐标换算也写死了 `NSScreen.main?.frame`，副屏选区会被映射到错误的位置。

**修复**：为每块屏构造各自的 `RegionSelectionView` 覆盖窗口，并把「所属 screen」随回调一路传下去做坐标换算（`rect` 用 `view.convert` 转到全局，再减 `screen.frame.origin`）。

### P1-3 标注窗口按 `NSScreen.main` 定位与缩放，与"截图来源屏"无关

**位置**：`Sources/AnnotationWindow.swift:22-43`（`screenFrame`/`fitScale`/`origin` 全部来自 `NSScreen.main`）；`Sources/AppDelegate.swift:112-115`（逻辑尺寸用 `NSScreen.main?.backingScaleFactor` 推算）

窗口的尺寸和居中位置都基于「当前 key window 所在屏」（`NSScreen.main` 的 SDK 注释就是 *"Screen with key window"*），而不是「截图来源屏」。本机实测（该进程里 `NSScreen.main` 是第三块屏）：

```
源图 200x150   → 窗口 origin = (-1394, 750)   ← 落在 x∈[-2048,0] 的第三块屏上
源图 600x400   → 窗口 origin = (-1458, 625)
源图 2560x1440 → 窗口 origin = (-1910, 486)
```

**影响面的准确边界**（第二轮复核修正）：正常流程下用户是点**菜单栏**（在主屏）触发截图的，此刻 `NSScreen.main` 有可能正好是主屏，所以"必定弹错屏"是过度断言。确定成立的是两点：
1. **语义错误**：`NSScreen.main` 从来不表示"截图来源屏"，用它决定窗口尺寸与位置在混合 DPI / 多屏下必然有算错的可能；
2. **时序脆弱**：`AnnotationWindow.init` 在**截图完成之后**才读 `NSScreen.main`，而那时覆盖窗口已经 `orderOut`、进程内常常没有 key window（实测 `keyWindow == nil`），这个值随时可能跟截图时不是同一块屏。`fitScale` 也随之按错误的屏幕尺寸计算。

**修复**：`RegionSelectionWindow` 把选中的 screen 一并回传，`AnnotationWindow(image:on screen:)` 用该 screen 的 `visibleFrame` 和 `backingScaleFactor`。

### P1-4 多个聚光灯重叠区域被重新压暗

**位置**：`Sources/AnnotationView.swift:818-837`

```swift
ctx.addPath(fullPath)          // 全图矩形 + N 个聚光灯矩形
ctx.clip(using: .evenOdd)      // ← 问题在这里
ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
ctx.fill(imageRect)
```

偶奇规则下，**同时落在两个聚光灯内的像素穿越数变成 3（奇数）→ 重新被算作"要压暗"**，于是两个聚光灯的交叉区域反而变黑；同时该区域又被 `:840-856` 的白光叠加两次。

实测（两个重叠聚光灯，读合成图像素亮度）：

```
非聚光灯区 = 0.450    单个聚光灯内 = 1.000    两灯重叠处 = 0.574   ← 明显变暗
```

`README.md:17` 明确写着「支持多个聚光灯叠加」，所以这是**实现与宣称不符**。

**修复**：不要用偶奇裁剪。改为「先铺半透明黑，再用 `.clear`/`destinationOut` 混合模式把聚光灯区域挖掉」，或把多个聚光灯路径做并集后按非零环绕规则裁剪。

### P1-5 Layer B 调试面板让拖拽每帧付出约 25ms

**位置**：`Sources/AnnotationView.swift:996-1000`（`refreshDebugView`）、`:98-127`（`debugVisualization` 每次 new 一个全尺寸 NSImage + `lockFocus` + 重绘全部对象）；调用点在 `:214`、`:226`、`:244`（每个 `mouseDragged` 都调）

实测（2560×1440 画布、20 个对象；两次独立测量结果接近，探针 `probe_perf` 可复跑）：

```
调试面板关闭：0.2 ms / 拖拽事件   （约 5900 次/秒上限）
调试面板开启：24.7 ~ 26.9 ms / 拖拽事件（约 37 ~ 40 次/秒上限）   ← 默认就是这个状态
对照：整屏 draw() 才 3.1 ~ 3.3 ms/帧
```

调试可视化比**真实渲染还贵约 8 倍**，而且没有任何开关（README 把它当特性宣传）。拖拽事件在触控板上可达 120Hz，主线程每次阻塞约 25ms → 拖拽明显掉帧、手感发粘。

**修复**：把调试面板改成菜单开关（默认关）；或把 `debugVisualization` 的渲染尺寸降到面板实际尺寸（现在是按画布全分辨率渲染再让 `NSImageView` 缩下去）；至少也应该只在 `mouseUp` 刷新，而不是每次 `mouseDragged`。

### P1-6 选中对象后 Option/Shift 拖拽画布任意位置都会改对象

**位置**：`Sources/AnnotationView.swift:130-149`

```swift
if let key = selectedKey, let obj = objects[key] {
    if flags.contains(.option) { state = .rotating(...); return }   // ← 不看点击位置
    if flags.contains(.shift)  { state = .scaling(...);  return }
}
```

这段判断在命中检测**之前**，且完全不检查鼠标是否落在选中对象上。实测：

- 在离对象很远的空白处 Option 拖拽 → 选中对象被旋转（合成图哈希发生变化）；
- 在空白处 Shift 拖拽 → **没有画出新矩形**，而是把选中对象缩放了。

用户的心智模型是「在空白处拖拽 = 画新图形」，这里被静默劫持了。

**修复**：只有当 `mouseDown` 落在选中对象的 `boundingBox`（或手柄/描边）内时才进入 rotating/scaling，否则走正常命中检测与绘制分支。

### P1-7 移动箭头会永久解除附着，撤销也救不回来

**位置**：`Sources/AnnotationView.swift:204-208`（`mouseDragged` 中无条件清空 attachment）、`:366-375`（`mouseUp` 只记录 `.move`，不记录被清掉的附着关系）

实测：矩形 + 附着箭头 → 轻推箭头 5pt（解除附着）→ `performUndo()` 撤销这次移动 → 再移动矩形：**箭头不再跟随**，附着关系永久丢失。而如果只拖动 1px（低于 `:370` 的 0.5pt 记录阈值），连撤销记录都不会产生，属于「不可撤销的副作用」。

**修复**：`UndoAction.move` 里带上被清除的 `Attachment`（或新增 `case detach`），撤销时恢复；更简单的是把「解除附着」推迟到移动量超过阈值之后再执行。

### P1-8 箭头永远无法附着到圆/椭圆：`nearestPerimeterPoint` 数学错误（偏差上千像素）

**位置**：`Sources/Models.swift:737-752`（`CircleShape.nearestPerimeterPoint`），失效闸门在 `Sources/AnnotationView.swift:883-890`

```swift
let dist = hypot(dx / radiusX, dy / radiusY)
let nx = dx / dist                     // ← 已经除以过 dist，下面又乘了一次半径
let ny = dy / dist
let localNearest = CGPoint(x: center.x + radiusX * nx, y: center.y + radiusY * ny)
```

展开后返回的是 `center + (radiusX·dx/dist, radiusY·dy/dist)`；而射线与椭圆的交点应是 `center + (dx/dist, dy/dist)`（取 t = 1/dist 恰好满足 (t·dx/rx)² + (t·dy/ry)² = 1）。**偏移量被多乘了一次半径**。当输入点本来就在椭圆上时 dist == 1，于是函数把输入点直接放大 (radiusX, radiusY) 倍返回。

实测（`center=(200,150)`, `radiusX=100`, `radiusY=50`，输入点都取在椭圆上）：

```
θ=0°   输入 (300.0, 150.0)  → 返回 (10200.0, 150.0)   误差 9900 px
θ=45°  输入 (270.7, 185.4)  → 返回 ( 7271.1, 1917.8)  误差 7212 px
θ=90°  输入 (200.0, 200.0)  → 返回 ( 200.0, 2650.0)   误差 2450 px
```

后果（端到端实测）：把箭头端点**精确落在椭圆轮廓上**，`detectAttachment` 用这个错误点去比 15px 阈值，必然落空 → **附着不成立**；随后拖动椭圆，箭头原地不动（实测 `arrow followed the ellipse: false / arrow stayed behind: true`）。也就是说 `radius > ~1.8px` 之后，**「圈出重点 → 画箭头指向它」这个最核心的标注用法在圆/椭圆上完全不可用**。

**修复**：

```swift
let nx = (dx / radiusX) / dist
let ny = (dy / radiusY) / dist
```

（等价于直接返回 `center + (dx/dist, dy/dist)`）。注意修复后该点落在椭圆上，`computePerimeterParameter` 的反函数关系不受影响 —— 那条链路本身是正确的。

### P1-9 旋转/缩放父形状时，已附着的箭头不跟随

**位置**：`Sources/AnnotationView.swift:217-227`（`.rotating` 分支）、`:229-245`（`.scaling` 分支）—— 两处都只调用了 `hitTestBuffer.redrawAll`，**没有调用 `updateAttachedArrows(forParent:)`**；而 `.moving` 分支（`:210`）以及 undo/redo 路径（`:481`、`:488`）都调用了。

即：`mouseDragged` 里 `obj.rotate(by:)` / `obj.scale(by:)` 只改了父对象自身，附着箭头端点的重算被漏掉了；`mouseUp` 也只记录 undo 动作、不补算，所以松手后错误状态会**一直保留**（只有再撤销/重做或移动一次父对象才会"追上"）。

实测（矩形 + 端点在角上的附着箭头，变换后用同一套探针检测旧附着点是否仍被占据，并以"移动"作为对照组）：

```
ROTATE -90°  → 旧附着点 (100,100) 仍可点中   → 箭头留在原地（父对象轮廓已不在该处）
SCALE x3     → 旧附着点 (100,100) 仍可点中   → 箭头留在原地（该点已在父对象内部，非轮廓）
MOVE（对角） → 旧附着点 (100,100) 点不中      → 箭头正确跟随（对照组通过）
```

独立复算：旋转 -90° 后箭头端点应到 `(120,180)`，实际仍停在 `(100,100)`；缩放 ×3 后应到 `(0,40)`，实际仍停在 `(100,100)`。

**修复**：在 `:221`（`obj.rotate(by: deltaAngle)`）与 `:237`（`obj.scale(by: factor)`）之后各补一行 `updateAttachedArrows(forParent: colorKey)`。

### P1-10 窗口截图的窗口挑选完全不过滤，且失败时静默无反应

**位置**：`Sources/ScreenCapture.swift:19-47`（挑选逻辑）；静默失败在 `Sources/AppDelegate.swift:97-101`

```swift
for info in windowList {                     // 取第一个命中者；实测层级高的排在前面
    guard let pid = ..., pid != myPID,
          let boundsDict = ..., let windowID = ... else { continue }
    if bounds.contains(testPoint) { return CGWindowListCreateImage(...) }   // ← 没有任何 layer/alpha/尺寸过滤
}
```

只排除了自身 PID，**没有要求 `kCGWindowLayer == 0`（普通应用窗口层）、`kCGWindowAlpha > 0`、尺寸 ≥ 1×1**。SDK 只承诺这个列表是 *"ordered from front to back"*，而实测**层级高的窗口排在最前面**，所以第一个命中者往往是系统级窗口而不是用户想截的那个应用窗口。

本机实测（65 个窗口，列表头部）：

```
[ 0] layer=2147483630  Window Server  28x40   @(-5,-5)
[ 1] layer=2147483646  Window Server  2560x1080 @(0,0)      ← 覆盖整块主屏
[ 2] layer=2147483646  Window Server  2048x1152 @(-2048,-360)
[ 3] layer=2147483646  Window Server  1512x982  @(-803,1080)
[ 4] layer=2004        loginwindow    2560x1080
[ 7] layer=2001        loginwindow    30000x30000 @(-15000,-15000)  ← 覆盖任意坐标
[ 8] layer=25          控制中心        74x33
```

（顺带一个交叉验证：同一个窗口列表里，AppKit 报第三块屏为 `(-2048, 288, 2048×1152)`，列表里对应的 Quartz 坐标是 `(-2048, -360)` —— 恰好等于 `1080 - (288 + 1152)`，从数值上印证了「原点在主显示器左上角、Y 向下」这条转换公式。）

按 `ScreenCapture` 的循环实际挑选结果：

```
代码挑选结果 : Window Server layer=2147483646 2560x1080
对该窗口截图 : nil            ← 于是 AppDelegate 的 `if let image` 直接跳过，什么都不发生
```

**用户可见症状**：点「窗口截图」，菜单关掉，然后……没有任何反应，没有报错、没有提示、没有声音。`startWindowCapture` 里 `captureWindowUnderMouse()` 返回 nil 时不做任何反馈。

同时在正常会话里，位于鼠标下方的状态栏项目（layer 25）、菜单栏（layer 24）、Dock（layer 20）、其他 App 的浮层/HUD/提示气泡（layer > 0）、以及 alpha 为 0 或 1×1 的辅助窗口都可能被选中；第二份 AISnap 实例（PID 不同）也会被截到。

> 说明：本次测量时系统处于锁屏/休眠状态（列表中出现了 `loginwindow`，会显著抬高头部窗口的层级），所以「必定选错」这一强度依赖会话状态；但**缺少 layer/alpha/尺寸过滤本身**是客观缺陷，在正常情况下也会选到菜单栏/Dock/HUD 这类不该截的窗口，并且一旦选中不可截窗口就会静默失效。

另外实测：**越界矩形的截图会返回一张合法的全透明图片**（`300x200`，中心 alpha = 0.0），不会返回 nil —— 也就是说坐标算错不会报错，只会给用户一张空白画布。

**修复**：在边界判断前加上 `layer == 0 && alpha > 0 && width >= 1 && height >= 1`；对 `nil` 结果给出提示或回退到全屏截图。

### P1-11 副屏区域截图的坐标换算漏掉了屏幕原点（会截到另一块屏）

**位置**：`Sources/RegionSelectionWindow.swift:69-75`

```swift
let screenFrame = NSScreen.main?.frame ?? .zero
let captureRect = CGRect(x: rect.origin.x,                       // ← 只有视图内坐标，没加屏幕原点
                         y: screenFrame.height - rect.origin.y - rect.height,
                         width: rect.width, height: rect.height)
```

`rect` 是覆盖窗口的**视图内坐标**（该窗口的 content view 已归一化到 (0,0)，因此视图坐标 == 窗口坐标），直接把它当成全局坐标用，就丢掉了宿主屏幕的 `frame.origin`。

`probe_region` 实测（目标屏 1512×982@(-803,-982)，视图内选区 `(756, 491, 200, 150)`）：

```
代码算出 captureRect = (756, 511, 200, 150)
正确应为            = (-47, 1421, 200, 150)
偏差 = (+803, -910) pt     ← 两次截图读出的像素内容不同
```

即丢失的正是宿主屏原点 `(-803, -982)` 以及翻转锚点的差异 —— 截到的是另一块显示器上的区域。

在单显示器、或 `NSScreen.main` 恰好是原点屏 (0,0) 时这个公式**完全正确**，所以作者在单屏环境下不会发现。

**修复**：用收到拖拽的那个窗口做换算，并把 Y 翻转锚定到主屏高度：

```swift
let r = window.convertToScreen(rect)
CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
```

### P1-12 `NSScreen.main` 的语义不是"0 号屏"（常见根因）

**位置**：`Sources/ScreenCapture.swift:35`、`Sources/AnnotationWindow.swift:22`、`Sources/AppDelegate.swift:112`、`Sources/RegionSelectionWindow.swift:69`

这一条是上面 P1-1/P1-3/P1-11 的共同根因。关键在于**名字相同、语义不同**：

```
NSScreen.h:  @property (class, readonly, nullable, strong) NSScreen *mainScreen;  /* Screen with key window */
CGWindow.h:  "The bounds of the window in screen space, with the origin at the
              upper-left corner of the main display."
```

`NSScreen.main` 是"**key window 所在的那块屏**"，而 Core Graphics 说的 "main display" 是"**带菜单栏的那块屏**"（`CGMainDisplayID()`，`frame.origin == .zero`）。代码把前者当后者用，于是 P1-1（翻转锚点）、P1-3（窗口定位）、P1-11（选区换算）都错了。

本机实测：`NSScreen.main` = `(-2048, 288, 2048, 1152)`（第三块屏），`NSScreen.screens[0]` / `CGMainDisplayID()` = `(0, 0, 2560, 1080)`，两者不同。

> **第二轮复核修正**：第一轮我写过"`NSScreen.main` 会跟着鼠标走"，这个**机制描述是错的** —— 实测鼠标在 (0,1080)（主屏范围内）时它依然返回第三块屏。那句结论来自子代理的 5/5 观察，我自己的数据不支持，已删除。**能确定的只是"它不等于主显示器，且语义上不该当坐标锚点"**，至于它具体何时变、变成哪块屏，取决于 key window 的状态，请用 `probe_screens` 在你自己的会话里观察。

**修复**：需要"坐标锚点"时用 `frame.origin == .zero` 的主显示器（或 `CGMainDisplayID()`），需要"截图来源屏"时把 screen 显式传递下去，任何地方都不要用 `NSScreen.main`。

---

## 4. P2 — 健壮性与体验

### P2-1 水印文本框必须按回车才生效

**位置**：`Sources/AnnotationWindow.swift:258-266`（只挂了 `action`）、`:429-431`

实测 `NSTextField.cell.sendsActionOnEndEditing == false` → `action` 只在 **Return/Tab** 时触发。用户输入自定义水印后直接点「保存」，`watermarkConfig.text` 仍是旧值（默认 `"AISnap"`），导出结果与输入不符，且没有任何提示。

**修复**：实现 `NSTextFieldDelegate.controlTextDidChange` 实时同步，或至少设 `cell?.sendsActionOnEndEditing = true`。

### P2-2 激活策略永久切换为 `.regular`，与 Info.plist/文档矛盾

**位置**：`Sources/AnnotationWindow.swift:145-146`（`setupMainMenu()` 里 `NSApp.setActivationPolicy(.regular)`）；`build.sh` 里 `LSUIElement = true`；`DESIGN.md` 第 11 节「运行后…无 Dock 图标」

首次打开标注窗口后应用变成 `.regular` 且**从不恢复**：Dock 里常驻图标、Cmd+Tab 可见、应用菜单常驻，而 Info.plist 和设计文档都声称是纯菜单栏应用（`.accessory`）。关掉标注窗口后应用会停留在「有 Dock 图标但没有窗口」的尴尬状态。

**修复**：在标注窗口 `windowWillClose` 时恢复 `.accessory`（或用 `windowDidBecomeKey/DidResignKey` 动态切换）。

### P2-3 关闭标注窗口会静默丢弃全部标注

`AnnotationWindow.swift:47` 带 `.closable`，但没有实现 `windowShouldClose`，关窗即销毁，且截图本身也不会保留。叠加 P0-2（没有保存入口）与 P2-1 之后，用户很容易白干一场。

**修复**：`undoStack` 非空时弹确认；或补 `Cmd+S`。

### P2-4 保存失败被静默吞掉

**位置**：`Sources/AnnotationWindow.swift:443-447`

```swift
try? pngData.write(to: url)
```

磁盘满、无权限、路径只读时用户看不到任何反馈，以为保存成功了。

**修复**：`do/catch` + `NSAlert`。

### P2-5 权限判定只信 `CGPreflightScreenCaptureAccess()`，且拿到图片后不做任何校验

**位置**：`Sources/AppDelegate.swift:17-30`（判定）、`:12`（只在启动时请求一次）

```swift
private func checkScreenCapturePermission() -> Bool {
    return CGPreflightScreenCaptureAccess()      // ← 唯一依据
}
```

**风险（未在本机复现，降级说明）**：`CGPreflightScreenCaptureAccess()` 在社区里有大量**假阴性**报告（TCC 缓存滞后、无 bundle 的 CLI 进程 responsible-process 归属问题）。一旦误报 false，`startRegionCapture`/`startWindowCapture` 会直接弹「请前往系统设置开启屏幕录制」，而用户明明已经授权 —— 且代码里没有任何绕过路径。我无法按需制造这个假阴性，所以这里只作为**设计风险**列出，不作为已复现缺陷。

**两条已复现的相关缺陷**：
1. **授权后不会重新检测**：请求只在启动时发起一次（`:12`）。用户去系统设置里打开权限后，当前进程仍然一直失败，直到重启 App。
2. **完全不校验截图结果**：没有权限或坐标算错时，`CGWindowListCreateImage` 会返回一张**非 nil 的空白/桌面图**。探针 `P2-6b` 实测：越界矩形 `(-5000,-5000,300,200)` 返回一张 `300×200`、中心 `alpha = 0.00` 的合法图片。代码会把它当成成功正常打开标注窗口，用户对着一张空图发呆。

**修复**：判定改成 `CGPreflightScreenCaptureAccess() || 真实 1x1 截图探测`；在 `applicationDidBecomeActive` 时重新检测；对全透明/空白结果做校验并报错。

### P2-6 逻辑尺寸靠 `NSScreen.main?.backingScaleFactor` 反推，混合 DPI 下会算错

**位置**：`Sources/AppDelegate.swift:112-115`

```swift
let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
let logicalSize = NSSize(width: CGFloat(image.width) / scaleFactor, ...)
```

问题有三：① `NSScreen.main` 可能已不是截图来源屏（见 P1-12）；② 捕获屏与 `NSScreen.main` 的 scale 不一致时会得到 2 倍/一半的逻辑尺寸；③ `?? 2.0` 在无屏场景会把 1x 图当 2x 处理。

`probe_export_scale` 实测（走 App 自己的 `compositeImage` → TIFF → PNG 链路，源图 5120×2160 / 2560×1080 像素）：

```
A  2x 截图 + 主屏 2x：应有逻辑 2560x1080pt，代码算出 2560x1080pt，导出 5120x2160px   ✓ 一致
B  2x 截图 + 主屏 1x：应有逻辑 2560x1080pt，代码算出 5120x2160pt，导出 10240x4320px  ✗ 4 倍像素、模糊放大
C  1x 截图 + 主屏 2x：应有逻辑 2560x1080pt，代码算出 1280x540pt， 导出 2560x1080px    ✗ 画布减半 → 15px 线宽/48px 贴纸/字号相对内容放大 2 倍
```

注意 B 与 C 的失效方式不同：B 让**像素**翻倍（导出图模糊），C 让**逻辑尺寸**减半（标注相对内容过大），导出像素反而"看起来正确"。`AnnotationWindow:29` 的 `fitScale` 会在屏幕上掩盖一部分尺寸错误，所以**损害主要体现在导出文件里**，而不是编辑界面。你这三块屏都是 2x，所以目前是潜在问题。

**修复**：由 `ScreenCapture` 在返回 `CGImage` 的同时返回捕获屏（或它的 scale），不要事后猜。

### P2-7 截图前的 0.2s / 0.5s 魔法延迟是竞态

**位置**：`Sources/RegionSelectionWindow.swift:78`（0.2s）、`Sources/AppDelegate.swift:97`（0.5s）

「等覆盖窗口消失」「等状态栏菜单收起」都靠固定 sleep。慢机器上窗口可能还没真正消失，截出来的图会带上遮罩层；快机器上则白白多等。DESIGN.md 第 6.1 节写的是 100ms，代码是 200ms，文档也已过期。

**修复**：区域截图改用 `.optionBelowWindow` 并传入覆盖窗口自身的 windowNumber，这样**不需要任何延迟**；窗口截图可用 `NSMenu` 关闭的回调或对菜单窗口号的显式排除来替代 sleep。

---

## 5. P3 — 工程与仓库卫生

### P3-1 `.build/` 产物已入库，`.gitignore` 形同虚设

`.gitignore` 只有一行 `AISnap.app`。实测：

```
受控文件总数            2438
其中 .build/ 下的文件   2409  (98.8%)
工作区 .build/ 体积     575 MB
.git 体积               93 MB
```

每次自动提交都把这堆二进制再存一遍，仓库正在持续膨胀，且 `git clone` 对新贡献者极不友好。

**修复**：`.gitignore` 增加 `.build/`、`.DS_Store`、`*.dmg`、`AISnap.app/`；`git rm -r --cached .build`；若在意历史体积再用 `git filter-repo` 清理。

### P3-2 `.qoder/auto_git_push.sh`：每 10 分钟自动 `git add -A` + push

- `REPO_DIR="/Users/fengyong/qoder/ai-snap"` 指向的路径在当前机器上**不存在**，脚本跑起来会直接 `cd` 失败退出；
- 即便路径正确，`git add -A` 会把 `.build/`、`.DS_Store`、`AISnap.dmg`、公众号文章一起推到公开 GitHub；
- 123 次提交几乎全是 `Auto commit at ...`，`git log` 完全失去回溯价值（本次审查中无法通过历史定位任何一次改动的原因）。

**修复**：删掉或改成只在 `Sources/`、`docs/` 有变化时提交，并使用有意义的 message。

### P3-3 `build.sh` 硬编码架构路径，且没有签名/公证

**位置**：`build.sh:5` `BUILD_DIR=".build/arm64-apple-macosx/release"`（`README.md:81` 的运行路径同样写死 arm64）

- 在 Intel Mac 上 SwiftPM 产出的是 `.build/x86_64-apple-macosx/release`，第 18 行的 `cp` 找不到文件，配合 `set -e` 会让整个脚本直接终止 —— **在 Intel 机器上完全没法打包**。应改为 `BUILD_DIR="$(swift build -c release --show-bin-path)"`。
- **完全没有 codesign / notarize / staple 步骤**。实测产出的二进制是 `flags=0x20002(adhoc, linker-signed)`、`Info.plist=not bound`、`TeamIdentifier=not set`、`Sealed Resources=none`。两个后果：① 产物 DMG 拿到别的 Mac 上会被 Gatekeeper 直接拦下，README 承诺的「可分发的安装包」并不成立；② ad-hoc 签名下 TCC 的身份依据是 **cdhash**，而每次 `swift build` 重新链接都会改变 cdhash —— **每次重新构建后，"屏幕录制"授权都会静默失效，用户必须重新授权一次**。建议：Developer ID 签名 + `notarytool` 公证；本地开发用一个稳定的自签名证书。
- Info.plist 里的 `NSScreenCaptureUsageDescription`（`build.sh:45-46`）**不是 Apple 的屏幕录制授权键**（屏幕录制 TCC 并不使用 usage description 字符串；全 SDK 检索也没有这个键），属于无效配置 —— 无害，但容易让人误以为已经声明过用途。
- Info.plist 缺 `CFBundleIconFile` / `CFBundleIconName`，应用与 DMG 都是通用图标。

### P3-4 没有任何测试

工程无测试 target，几何计算、命中检测、撤销/重做、坐标换算这些**最容易回归**的部分完全裸奔。本次审查用的临时 harness（`/tmp/aisnap-*`）已经覆盖了命中检测、撤销重做、附着跟随、聚光灯合成、性能，可以直接改造成 `Tests/AISnapTests`。

### P3-5 文档与实现已经脱节

| 文档 | 描述 | 实际 |
|------|------|------|
| `README.md:88` | 「约 2,860 行」 | 3164 行 |
| `DESIGN.md` §5 | `CanvasState` 只有 idle/drawing/moving 三态 | 6 态（含 rotating/scaling、`drawing(tool:start:)`） |
| `DESIGN.md` §8 | 渲染顺序 = 底图 + 箭头 + 预览 | 还有聚光灯遮罩、贴纸、水印；且「全量重绘无性能问题」与实测 27ms/事件矛盾 |
| `DESIGN.md` §6.1 | 延迟 100ms | 代码 200ms |
| `DESIGN.md` §9 | 键盘表只有 Escape / Delete | 缺 Cmd+Z、Cmd+Shift+Z、ESC 取消选中、Option/Shift 变换 |
| `DESIGN.md` §10 | 「首次调用 `CGWindowListCreateImage` 时系统弹窗」 | 启动即 `CGRequestScreenCaptureAccess()` |
| `DESIGN.md` §11 | 「无 Dock 图标」 | 打开标注窗口后 `setActivationPolicy(.regular)` |
| `DESIGN.md` §11 | 建议 `swift run AISnap` | 裸二进制没有 bundle id，TCC 会把「屏幕录制」权限记到**终端**头上；应改用 `build.sh` 产出的 `.app` |

---

## 6. P4 — 细节、低优先级与补充结论

> 本清单混合了三类内容，请注意区分：① 低优先级缺陷 = 第 1-9、14-20 条；
> ② 显式标注为"可接受/仅提示"的 = 第 10 条；③ 复核后确认**正确**、但值得记录下来免得后人重复怀疑的结论 = 第 11-13 条。

1. **选区虚线边框被自己擦掉一半** — `RegionSelectionWindow.swift:143-152` 先 `stroke` 再 `.clear` 填充选区内部，内半边线宽（0.75pt）被抹掉。应先 `clear` 再 `stroke`。
2. **ESC 取消 / 首次点击的响应链没有保障** — `beginSelection()`（`RegionSelectionWindow.swift:53-59`）既没有 `makeFirstResponder(selectionView)` 也没有 `NSApp.activate`。实测事实：① `RegionSelectionView.acceptsFirstMouse` 返回 **false**；② 应用未激活时 `beginSelection()` 之后 `isKeyWindow == false`、`NSApp.keyWindow == nil`。因此当应用不是最前台时，**第一次点击会被当作"激活点击"吞掉**，ESC 会被送到当时最前台的那个 App，根本到不了 `keyDown`。视图自身的处理是对的（把合成 ESC 发给可见窗口，取消回调正常触发、覆盖层正常消失），所以这是"没有保障"而不是"必定失效"—— 但代码里没有任何地方能保证应用处于激活态。建议：`beginSelection` 前 `NSApp.activate(ignoringOtherApps: true)`（`openAnnotationWindow` 有，这里漏了）+ 覆写 `acceptsFirstMouse(for:) -> true` + 显式 `makeFirstResponder`。
3. **箭头可以附着到聚光灯，但永远不会跟随** — `AnnotationView.swift:864-893` 的 `detectAttachment` 不排除 `SpotlightShape`，会产出 `.perimeter(...)`；而 `resolveAttachmentPosition`（`:946-956`）对聚光灯返回 `nil`，`computePerimeterParameter`（`:896-934`）也只处理 circle/rect/stamp。实测：箭头端点停在原处不动。应排除 Spotlight 或为其实现 `pointOnPerimeter`。
4. **`HitTestBuffer` 没有做 CGContext 状态隔离** — `drawObject`/`redrawAll`（`HitTestBuffer.swift:74-93`）依赖每个对象自己重置 lineDash/线宽/颜色；`clear()` 也不重置 lineDash。当前恰好没出错（`Arrow.drawArrow` 用完就重置），但新增图形类型时极易串状态。建议每个对象 `saveGState()/restoreGState()` 包裹。
5. **redo 方向靠"对象是否存在"猜测** — `AnnotationView.swift:507-524` 用 `objects[firstKey] != nil` 判断是"重做删除"还是"重做添加"。实测 9 步混合序列的撤销/重做**完全正确**（见 §7），但这个隐式约定很脆：`savedObjects[0]` 的顺序依赖 `mouseDown` 里"先塞父对象再塞级联箭头"的写法，一旦有人改动拼接顺序就会静默出错。建议拆成 `case add` / `case remove` 两个显式动作。
6. **字典遍历顺序影响吸附/附着的选择** — `findNearestSnapPoint`（`:755-770`）与 `detectAttachment`（`:864-893`）遍历 `[UInt32: AnnotationObject]`。距离不同时结果唯一，**距离完全相同时**（对称图形、等距中点）结果不确定。建议按 zOrder 顺序遍历。
7. **缩放不缩放线宽与箭头头部** — `Models.swift:474-478`、`:651-654`、`:774-777` 只改几何尺寸，`lineWidth`/`style.headLength` 不变，放大后线条视觉上变细（矩形）而箭头只变长不变粗。
8. **导出分辨率取决于当前显示器** — `AnnotationView.swift:1005-1026` 用 `NSImage.lockFocus()`。实测本机（2x 屏）600×400pt → 1200×800px，**分辨率没有损失**；但该行为依赖"当前屏是 2x"。若在 1x 外接屏上标注 2x 截图，导出的 PNG 会退回 1x。建议显式用 `NSBitmapImageRep(bitmapDataPlanes:...)` 按原图**像素**尺寸建立上下文。
9. **`saveImage` 的 PNG 走 TIFF 中转**（`AnnotationWindow.swift:443-445`）多做一次全图编解码，大图上是可感知的额外开销与内存峰值；直接用 `NSBitmapImageRep(cgImage:)` 更省。
10. **`fatalError("init(coder:)")`**（`AnnotationView.swift:54`）可接受（无 nib 使用），仅提示。
11. 所有 `!` 强制解包（`HitTestBuffer.swift:23`、`Models.swift:521-523,608,923,1012-1014,1082`）都作用于**非空集合**或必然成功的构造，经核对**无崩溃风险**。
12. **吸附点索引方案本身是可靠的**：`snapPoints()` 顺序确定（重复 50 次逐位相同），`detectAttachment` 写入的 `.snapPoint(index:)` 在父对象移动/旋转/缩放后仍指向同一个几何特征（Rectangle 9/9、Circle 5/5、Stamp 5/5、Spotlight 5/5 全部通过），`resolveAttachmentPosition` 读回的坐标与当初匹配到的点误差 0.000000000 px。箭头也不会成为父对象（`detectAttachment` 已排除）。
13. **`computePerimeterParameter` 与 `pointOnPerimeter` 互为逆函数**：`CircleShape` 精确（2 万采样误差 0.000000000 px）；矩形/贴纸在角点 0.1px 带内误差 ≤ 0.1px，无可见跳变；`200×0`、`0×200`、`0×0` 等退化形状往返几何精确且不产生 NaN（零周长时参数被钳制为 1.0）。
14. **吸附预览阈值 12px 与附着阈值 15px 不一致**（`AnnotationView.swift:31` vs `:861`）会导致松手瞬间端点跳一下：端点落在距轮廓 14px 处时，预览停在落点、松手后被吸附到轮廓上（实测跳变 14.00px）。若认为这是缺陷，把两个阈值统一即可。
15. **色键在 16,777,216 个对象后回绕**（`HitTestBuffer.swift:33-41`，已实测确认第 16,777,216 次调用重新发出 key=1）。届时 `Attachment.parentKey` 可能指向另一个对象。现实中不可能达到，仅作记录。
16. **重复触发区域截图会漏掉上一轮的覆盖窗口** — `AppDelegate.swift:78-84` 直接给 `regionSelectionWindow` 赋新值，没有先 `cancelSelection()`。实测（连续创建两个 `RegionSelectionWindow` 并统计本进程在屏窗口数）：**旧窗口并不会因为引用被覆盖而下屏，在屏窗口数从 3 个变成 6 个** —— 因为 `NSApplication.windows` 会持有窗口，ARC 释放引用不等于关闭窗口。后果是两层 30% 黑遮罩叠加（画面明显更暗），而且**旧覆盖层仍然是活的、仍能接收拖拽**，它的完成回调会把 `AppDelegate.regionSelectionWindow` 置为 nil，从而把新窗口的引用也弄丢。另外 `beginSelection()` 里的 `NSCursor.push()` 也不会被 `pop()` 抵消（代码路径上确实没有配对的 pop）。可达性低（覆盖层盖住了状态栏图标，正常点不到菜单），但确实是状态污染而非单纯泄漏。
17. **区域选择没有取消入口** — `RegionSelectionWindow` 没有右键取消、没有超时、也没有覆写 `cancelOperation(_:)`。叠加 P1-2/P4-2 之后，在非主屏上覆盖层只能用"在 NSScreen.main 那块屏上拖一次 >5pt 的选区"来解除（实测：<5pt 的点击不会关闭它）。建议加 `cancelOperation(_:)` 与右键取消。
18. **`showPermissionAlert()` 用 `runModal()` 但没先激活应用**（`AppDelegate.swift:32-43`）—— `.accessory` 应用若不激活，警示框可能出现在其他窗口后面或拿不到焦点，用户看到的是"点了菜单没反应"。`runModal` 前先 `NSApp.activate`。
19. **切换调色板后工具栏不重排，色板压住后面的控件**（第二轮 review 新增）— `AnnotationWindow.swift:401-404` 的 `cyclePalette()` 只调用 `rebuildColorButtons()` 重建色点，而后续控件的位置是在 `createToolbar` 里按**初始调色板的颜色数量**一次性算好的（`:208` 用了 `ColorPalette.allPalettes[paletteIndex].colors.count`）。因此从 4 色的「鲜明」切到 5 色的「专业/柔和」时，第 5 个色点会越界压到分隔线与「线宽」标签上。`probe_layout` 实测：色板右边界 452 → 482，后续控件起点 470，**重叠 12pt**。修复：把颜色数量变化也纳入重排（或把色板容器宽度固定为最大色数）。
20. **标注过程中再次触发截图会无确认地丢弃当前全部标注**（第二轮 review 新增）— `AppDelegate.swift:75-76` 与 `:93-94` 在开始新截图前无条件执行 `annotationWindow?.close()`。状态栏菜单永远可用，所以用户标注到一半手滑点一下「区域截图」，整幅标注（连同撤销栈）当场消失，没有任何确认。修复：`undoStack` 非空时先确认，或保留窗口/图片以便恢复。

---

## 7. 经实测确认「没有问题」的部分

为避免过度负面，以下都是本报告主动验证过、结论为**正确**的设计与实现：

1. **双图层 Color Picking 命中检测真正可用**（探针 `HIT-1..6` 全部 PASS）：矩形描边选中 ✓、矩形内部空白不误选 ✓、箭头杆选中 ✓、椭圆轮廓选中 ✓、椭圆内部不误选 ✓、贴纸放置/再选中 ✓。
2. **撤销/重做状态机正确**（探针 `UNDO-1/2` 全部 PASS）：9 步混合操作（画矩形 → 画附着箭头 → 移动父对象 → Option 旋转 → Shift 缩放 → 放贴纸 → 删贴纸 → 画椭圆 → 删椭圆）全部撤销后与初始空白态**像素级一致**，再全部重做后与最终态**像素级一致**。
3. **级联删除 + 撤销/重做正确**：删除父形状会连带删除附着箭头，撤销能同时恢复两者，重做能再次同时删除。
4. **附着跟随 —— 仅"移动"正确**：移动父对象后箭头端点正确跟随到新的吸附点（对照组通过，旧附着点变为空）。但**旋转/缩放不跟随（P1-9）**，且**圆/椭圆完全无法附着（P1-8）**。
5. **导出分辨率正确**：2x 屏上 `lockFocus` 产出 2x 位图，600×400pt 源导出 1200×800px，未损失原始像素。
6. **整屏重绘性能可接受**：2560×1440 + 20 对象全画布 `draw()` 仅 3.3ms。
7. **无并发问题**：全部逻辑在主线程，`DispatchQueue.main.asyncAfter` 的两处回调都做了 `[weak self]`，未发现保留环或数据竞争。
8. **无第三方依赖**，8 个文件职责划分清晰，`AnnotationObject` 协议抽象让新增图形类型的确只需实现 `draw`/`drawHitTest` 等少数方法（DESIGN.md §12 的扩展性论证成立）。
9. 强制解包、`as!`、越界访问经逐条核对均安全；`fatalError` 仅在无 coder 路径。
10. 当前部署目标下 `swift build` **零 warning 零 error**。
11. **`main.swift` 正确**：`let delegate = AppDelegate()` 是顶层变量（全局存储），`NSApplication.delegate` 是 weak 引用也不会被释放；菜单栏应用在启动阶段也不需要 `activate`。
12. **窗口几何构造正确**（注意：这只说明"窗口摆对了"，不代表副屏能用 —— 那属于 P1-2）：`RegionSelectionWindow` 用负原点的 `screen.frame` 构造窗口，实测 `window.frame == (-2048,288,2048,1152)`、content view 归一化为 `(0,0,2048,1152)`，因此视图坐标恰好等于窗口坐标；覆盖窗口集合在几何上确实覆盖了全部屏幕；`.statusBar + 1`（26）确实高于菜单栏（25）；`<5×5` 的选区守卫能挡住空选区。
13. **光标栈平衡**：`NSCursor.push()/pop()` 在"完成选择"和"取消选择"两条路径上都配对（唯一例外见 P4 第 16 条的重复触发场景）。
14. **`kCGWindowBounds as? [String: CGFloat]` 转换可用**（探针的窗口挑选逻辑全程依赖它并按预期取到了每个窗口的 bounds），`.boundsIgnoreFraming` + `.bestResolution` 的组合正确，X 不需要翻转、只有 Y 需要 —— 坐标模型本身理解无误，错的只是翻转锚点。
15. **`CGWindowListCreateImage` 在 macOS 26.5.1 上运行期仍可用**：探针在本机直接调用它并取回了合法图像（越界矩形返回透明图、Window Server 窗口返回 nil），没有崩溃也没有返回错误 —— 也就是说 obsolete 目前只卡编译期，运行期还没坏掉。

---

## 8. 建议的修复顺序

1. **P0-2 工具栏溢出** —— 改动最小、收益最大。让「保存/复制」在任意截图尺寸下都可达，并顺手补 `Cmd+S`/`Cmd+C`。
2. **P1-8 + P1-9 附着两个 HIGH** —— 各 1~3 行改动（一处除法、两行补调用），但直接决定「画圈+箭头指向」和「旋转/缩放后箭头是否还指着」这两个核心用法能否成立。
3. **P1-5 调试面板默认关闭** —— 一行开关就能把拖拽从 37fps 上限恢复到 5000+。
4. **P1-12 消灭所有 `NSScreen.main`** —— 这是 P1-1/P1-2/P1-3/P1-11 的共同根因：把它换成"坐标锚点用 `screens[0]`、来源屏显式传递"之后，多显示器的四个 bug 会一起消失；在你这台 3 屏机器上立刻可见。
5. **P1-10 窗口挑选加 layer/alpha/尺寸过滤 + 失败提示** —— 让「窗口截图」这个入口真正能用（目前实测是静默无反应）。
6. **P1-4 聚光灯叠加** + **P1-6 Option/Shift 劫持** + **P1-7 附着丢失** + **P1-11 副屏坐标** —— 四个独立的功能性 bug。
7. **P2 各项** —— 多数是几行代码。P2-5 的两条已复现缺陷（授权后不重检、不校验截图结果）优先。
8. **P3-1/P3-2 仓库卫生** —— 越早清理越省事（历史体积只会继续长）；P3-3 的签名问题在做分发前必须解决。
9. **P0-1 ScreenCaptureKit 迁移** —— 工作量最大，但不做的话整个项目的技术天花板就被钉死在 macOS 13；建议与前 8 项解耦，单独排期。

> 每修完一项，用 §9 的探针对应条目复跑即可确认：`./probes/run_all.sh <关键字>`。
> 探针从 `[FAIL]` 变成 `[PASS]` 就是修好了；`UNDO-*` / `HIT-*` 是防止改坏的回归基线。

---

## 9. 复核用的探针套件（`probes/`）

报告里的每条结论都固化成了可执行探针，用来替代"信我"：

```bash
./probes/run_all.sh              # 全部（当前合计复现 25 条）
./probes/run_all.sh geometry     # 只跑某一组
```

**做法**：探针不复制被测逻辑，而是把 `Sources/*.swift` 与探针一起编译，用真实的 `NSEvent`、
真实的 `NSWindow`、真实的 `CGWindowList*` 走生产代码路径，再把「实测值」与「应有值」并排打印。

| 探针 | 覆盖条目 | 本轮结果 |
|------|----------|----------|
| `probe_deployment_target.sh` | P0-1 | 复现 1 |
| `probe_layout` | P0-2、P4-19 | 复现 3 |
| `probe_geometry` | P1-8、P1-9、P4 第 14 条（+ 第 13 条 `pointOnPerimeter` 自检 PASS） | 复现 5 |
| `probe_canvas` | P1-6、P1-7（+ HIT/UNDO 基线 8 项 PASS） | 复现 3 |
| `probe_spotlight` | P1-4 | 复现 1 |
| `probe_perf` | P1-5 | 复现 1 |
| `probe_export_scale` | P2-6（A 场景 PASS，B/C 场景各 1 条） | 复现 2 |
| `probe_watermark` | P2-1 | 复现 1 |
| `probe_screens` | P1-1、P1-10、P1-12、P2-5 的失败模式 | 复现 4 |
| `probe_region` | P1-2、P1-11 | 复现 2 |
| `probe_signing.sh` | P3-3 | 复现 2 |

使用前请注意三件事（详见 `probes/README.md`）：

1. **会话状态会影响 `probe_screens` / `probe_region` 的具体数值**。本机审查期间处于锁屏状态
   （窗口列表里出现 `loginwindow`、鼠标坐标被钉在屏幕角落、`NSApp.isActive` 恒为 false），
   偏移多少 pt、挑中哪个窗口这类数字请解锁后复跑对照；代码缺陷本身由 SDK 文档即可判定，不受影响。
2. `probe_region` 比较截图内容的部分**需要屏幕录制权限**，未授权时会被标成 `[INFO]` 而不是 `[PASS]`。
3. 探针固定用 `-target <arch>-apple-macosx13.0` 编译 —— 这不是随意选的，而是 P0-1 的直接后果：
   换成 15.0 连探针都编译不过。

**探针自己也出过一次错**（值得记录）：第一版 `probe_canvas` 报「撤销/重做不一致」，
排查后发现是探针的 `selects()` 辅助函数用"在空白处点一下"来清空选中，
而在贴纸工具下这一下会真的放下一个贴纸、污染撤销栈。改成用 ESC 清空后，
`UNDO-1/UNDO-2`（9 步混合操作像素级往返）全部通过，与 §7 的结论一致。**探针本身也要被怀疑。**

---

## 10. 修复记录（2026-09-17）

工作方式：每改一处 → `swift build`（零警告）→ `./probes/run_all.sh` 看对应条目从 `[FAIL]` 翻成 `[PASS]`。
**复现缺陷数从 25 降到 1**（仅剩 P0-1，见文末说明）。

| 条目 | 状态 | 改动 | 验证 |
|------|------|------|------|
| P0-2 工具栏溢出 | ✅ 已修 | `AnnotationWindow` 先算工具栏所需宽度再决定窗口宽度；新增「文件」菜单的 Cmd+S / Cmd+C | `probe_layout` P0-2 / P0-2c PASS |
| P1-1 翻转锚点 | ✅ 已修 | 改用 `CGEvent(source: nil).location`（本就位于 Quartz 坐标系），彻底不做手工翻转 | `probe_screens` P1-1 PASS |
| P1-2 副屏不可选 | ✅ 已修 | `RegionSelectionWindow` 重写为"每块屏一个覆盖窗口 + RegionSelectionView" | `probe_region` P1-2 PASS（实测 3/3 屏） |
| P1-3 窗口定位 | ✅ 已修 | 捕获屏随 `CaptureResult` 传递，标注窗口按该屏的 `visibleFrame` 定位与缩放 | `probe_screens` / 构建后目视 |
| P1-4 聚光灯叠加 | ✅ 已修 | 遮罩改为在 transparency layer 内 `.clear` 挖空；高亮用并集路径一次填充 | `probe_spotlight` P1-4b PASS |
| P1-5 调试面板 25ms | ✅ 已修 | **默认关闭**，改由「视图 → 显示 Layer B 调试面板」(⇧⌘D) 按需开启；未挂载时零开销 | `probe_perf` / `probe_layout` PASS |
| P1-6 修饰键劫持 | ✅ 已修 | Option/Shift 仅在按点落在选中对象包围盒内时才进入旋转/缩放 | `probe_canvas` P1-6a/6b PASS |
| P1-7 附着丢失 | ✅ 已修 | `UndoAction.move` 携带 `DetachedAttachments`，撤销会恢复附着关系 | `probe_canvas` P1-7 PASS |
| P1-8 椭圆附着数学 | ✅ 已修 | `nearestPerimeterPoint` 去掉多乘的一次半径（`center + (dx/t, dy/t)`） | `probe_geometry` P1-8a/8b PASS |
| P1-9 旋转/缩放不跟随 | ✅ 已修 | `.rotating` / `.scaling` 分支补 `updateAttachedArrows` | `probe_geometry` P1-9b/9c PASS |
| P1-10 窗口挑选 | ✅ 已修 | 抽出纯函数 `windowCandidates`，要求 `layer==0 && alpha>0 && 尺寸≥1`；失败时弹提示 | `probe_screens` P1-10 PASS（7 个构造窗口只剩 1 个合法） |
| P1-11 副屏坐标 | ✅ 已修 | 抽出 `quartzRect(forViewRect:on:)`：加屏幕原点 + 主屏高度翻转 | `probe_region` P1-11/11b PASS |
| P1-12 `NSScreen.main` | ✅ 已修 | 代码中不再用它做坐标锚点或来源屏（仅保留一处作为无屏兜底） | `probe_screens` PASS |
| P2-1 水印不生效 | ✅ 已修 | `NSTextFieldDelegate.controlTextDidChange` 实时同步 + `sendsActionOnEndEditing` | `probe_watermark` PASS |
| P2-2 激活策略 | ✅ 已修 | `windowWillClose` 恢复 `.accessory` | 代码审查 |
| P2-3/P4-20 静默丢弃 | ✅ 已修 | `confirmDiscardIfNeeded()`：关窗与重新截图前都会确认 | 代码审查 |
| P2-4 保存失败静默 | ✅ 已修 | `try?` → `do/catch` + 失败弹窗 | 代码审查 |
| P2-5 权限判定 | ✅ 已修 | preflight + 真实 1×1 截图探测双保险；回前台自动重试；截图失败有提示 | 代码审查 |
| P2-6 逻辑尺寸 | ✅ 已修 | 逻辑尺寸由 `CaptureResult.logicalSize` 从捕获屏 scale 推出 | `probe_export_scale` 三种场景 PASS |
| P2-7 魔法延迟 | ✅ 已修 | 区域截图改用 below-window 捕获，**完全去掉 0.2s 等待**（实测亮度差 0.298 证明遮罩没被拍进去） | `probe_region` P2-7 PASS |
| P3-3 构建/签名 | ✅ 已修 | `--show-bin-path`；补图标/分类/版本等 plist 键；默认用 `AISnap Local Signing` 稳定身份签名；新增 `--install` | `probe_signing` 全 PASS |
| P4-1 边框被擦 | ✅ 已修 | 先 `.clear` 选区、再描边 | 代码审查 |
| P4-2 ESC/首次点击 | ✅ 已修 | `acceptsFirstMouse` + `makeFirstResponder` + `NSApp.activate` + `cancelOperation` | 代码审查 |
| P4-3 聚光灯附着 | ✅ 已修 | `detectAttachment` 排除 `SpotlightShape` | 代码审查 |
| P4-4 Layer B 状态隔离 | ✅ 已修 | 每个对象 `saveGState/restoreGState`；`clear()` 重置线型/线宽/混合模式 | 代码审查 |
| P4-8 导出分辨率 | ✅ 已修 | 显式 `NSBitmapImageRep` + 源像素尺寸（由 AppDelegate 显式传入） | `probe_export_scale` P4-8 PASS |
| P4-14 阈值不一致 | ✅ 已修 | 附着阈值与吸附阈值统一（均为 12pt） | `probe_geometry` P4-14 PASS |
| P4-16 窗口残留 | ✅ 已修 | `teardown()` 里 `orderOut + close`；重复触发前先 `cancelSelection()` | `probe_region` P4-16 PASS |
| P4-19 色板压控件 | ✅ 已修 | 切换调色板后整体重建工具栏并重排 | `probe_layout` P4-19 PASS |
| **P0-1 obsolete API** | ⏸ **未修（有意保留）** | 见下 | `probe_deployment_target` 仍 FAIL（预期） |

### 为什么 P0-1 这次不修

`CGWindowListCreateImage` 迁移到 ScreenCaptureKit 是一次**架构级重写**，不是补丁：

* ScreenCaptureKit 的 `SCScreenshotManager` 是 **async** API，会传染整个截图链路（AppDelegate → 选区窗口 → 标注窗口）；
* `SCScreenshotManager` 要求 **macOS 14+**，而当前部署目标是 13 —— 迁移等于放弃 macOS 13；
* 该 API 在**运行期仍然可用**（本机 macOS 26.5.1 上探针实测能正常取到图像），也就是说现在并没有坏，只是"编译期不能再提高部署目标"。

所以更合理的做法是把它当作一次独立的排期（报告 §8 第 9 条），而不是混在这次修复里。**在此之前请不要把 `Package.swift` 的 `platforms` 提到 15 以上**，否则会直接编译失败。

### 本次修复引入的一处行为变化（需要知道）

小尺寸截图（宽度 < ~600pt）的标注窗口现在会**变宽**（例如 300×200 的截图 → 940pt 宽的窗口），
因为窗口宽度必须容下工具栏，否则「保存/复制」又会跑到窗口外。画布尺寸不变，右侧会留白。
这是 P0-2 的直接取舍：**宁可窗口宽一点，也不能让导出按钮点不到**。

### 10.1 修复过程中自己引入并修掉的一个回归（多屏只有一个屏能框选）

用户实测反馈："3 个屏幕只能选择其中一个"。排查后确认是**我在上一轮修复里引入的回归**，这里如实记录：

**原因**：`RegionSelectionWindow.buildOverlays()` 里给 `NSWindow` 传了 `screen:` 参数：

```swift
OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
              backing: .buffered, defer: false, screen: screen)   // ← 多传了这个
```

传了 `screen:` 之后，AppKit 会把 `contentRect` 当作**相对该屏幕**的坐标，于是副屏窗口的原点被再加了一次屏幕原点：

```
屏0 真实位置 (0, 0)          → 窗口 frame {0,0}            （×2 仍是 0，所以只有它能用）
屏1 真实位置 (-803, -982)    → 窗口 frame {-1606,-1964}    （×2 → 跑到所有显示器之外）
屏2 真实位置 (-2048, 288)    → 窗口 frame {-4096,576}      （×2 → 跑到所有显示器之外）
```

窗口被扔到桌面之外，用户在副屏上既看不到遮罩、也点不到，表现就是"只有一块屏能框选"。

**修复**：不传 `screen:`，只给全局坐标的 `contentRect`，让 AppKit 自己判断落在哪块屏；
同时把 `(window, screen)` 成对保存，不再依赖 `NSWindow.screen`（窗口未落屏或显示器睡眠时它会返回 nil）。
另外把窗口查找从 `overlays.first { $0.screen == screen }` 改成 `===` 身份比较。

**修复后实测**（`probe_region` P1-2b/P1-2c）：

```
屏0 2560x1080@(0,0)        → ✅ 选区 1280x540 px
屏1 1512x982@(-803,-982)   → ✅ 选区  756x490 px
屏2 2048x1152@(-2048,288)  → ✅ 选区 1024x576 px
每个覆盖窗口都精确覆盖它所属的屏幕 — 3/3
```

**探针为什么没提前发现**：原来的 `probe_region` 只断言"每块屏都有一个带 RegionSelectionView 的窗口"，
**没有校验窗口位置**。窗口存在 ≠ 窗口在对的地方。现在补了两条断言：
`P1-2b` 要求窗口 frame 与所属屏幕 frame 完全相等；`P1-2c` 要求**在每块屏上真的模拟一次拖拽**并拿到图像。
这类"位置/几何"缺陷光看结构是看不出来的，必须逐屏跑一遍真实路径。

### 10.2 箭头渲染修复（用户实测反馈："箭头非常不好看"）

用户截图里那根"粗红条"其实是一个箭头 —— **它的箭头被箭杆吞掉了**。

**原因**：头部长度是固定值 `ArrowStyle.headLength = 14`，而默认线宽是 15px。
三角形头部的宽度 = 2·headLength·sin(headAngle) = 2×14×sin30° = **14pt**，
比箭杆宽度（15pt）还窄 → 三角形完全落在箭杆内部，画出来就是一根圆头粗棒。

**修了三处**：

1. **头部随线宽缩放**（`Arrow.effectiveHeadLength = max(style.headLength, lineWidth × 3.2)`）。
   默认 15px 线宽 → 头部 48pt，宽高都约为箭杆的 3 倍，终于像箭头了；
   细线（≤4px）保持原来的 14pt 不变，观感不变。
   顺带把尾部的圆点/垂直短线也改成随线宽缩放（原来固定 4pt，在 15px 线上就是个小点）。

2. **箭杆与头部的接缝**：实心三角/菱形头部有实体覆盖接缝，箭杆提前 0.85·headLength 结束
   （否则 `.round` 端帽会从尖端多伸出一个半圆）；**开放头部（两条线）没有实体**，
   箭杆必须画到尖端 —— 第一版漏了这个区分，15px/25px 的开放箭头出现了明显断口。

3. **命中层不能跟着收短**（这条是探针抓出来的回归）：可见层的三角头尖端是亚像素尖角，
   而 Layer B 关闭了抗锯齿 → 那一片采不到任何像素，**箭头端点变得抓不住**。
   命中层改为"整条粗线 + 圆头端帽一直画到尖端"。

**验证**：新增 `probes/render_arrows.swift`，把 6 种样式 × 6 种线宽渲染成一张对照图供肉眼检查
（`./probes/run_all.sh arrows`）；命中/附着相关断言（`HIT-*`、`P1-9*`、`P4-14`）全部保持通过。

### 10.3 换色：选中对象不会被重新上色（用户实测反馈："换色之后用的还是之前的颜色"）

先复现，把"换色"拆成三条路径分别验证：

| 路径 | 修复前 | 说明 |
|------|--------|------|
| 点色点 → 之后新画的对象 | ✅ 正常 | 实测 red → green，颜色确实变了 |
| 点「换色」切色板 → 之后新画的对象 | ✅ 正常 | 4 色 → 5 色，新对象用新色板的首色 |
| **选中已有对象 → 点色点** | ❌ **完全没反应** | 对象保持原色 —— 这就是用户遇到的现象 |

原因是设计缺失：`colorButtonClicked` 只写 `annotationView.currentColor`（只影响"之后新画的对象"），
**从头到尾没有任何"修改已选中对象颜色"的代码路径**。

**修复**：

1. `AnnotationView` 新增 `restyleSelection(color:lineWidth:)`：改选中对象的颜色/线宽，并记录一条
   新的撤销动作 `UndoAction.restyle(oldColor:newColor:oldLineWidth:newLineWidth:)`，撤销取旧值、重做取新值。
2. `colorButtonClicked` 现在两件事一起做：更新 `currentColor`（影响新对象）**并**给选中对象换色。
3. 顺手把线宽滑杆也接上同样的行为（选中对象 → 拖滑杆 → 该对象变粗），
   否则用户接下来一定会问"线宽为什么也改不了"。
4. **工具栏反向同步**：`AnnotationView.selectedKey` 变化时通过 `onSelectionChanged` 回调，
   把调色板高亮与线宽滑杆同步成"当前选中对象的样式"，这样选中一个红箭头就能看出它是红的。
5. `SpotlightShape` 的边框之前硬编码 `systemYellow`、完全忽略自身 `color`，
   现在改为使用 `color`（默认仍为黄色，视觉不变），使"选中后换色"对聚光灯同样生效。

**验证**：新增 `probes/probe_colors.swift`（真实点击路径 `hitTest` + 真实事件 + 采样合成图像素颜色）：

```
P1-13a  色点可被真实点击命中                    ✅ 4/4
P1-13b  点色点后新画的对象使用新颜色            ✅ red → green
P1-13b2 改色只影响新对象，已画好的对象不受影响  ✅
P1-13c  选中已有对象后点色点，该对象会换色      ✅ red → yellow
P1-13d  撤销可以恢复被改掉的颜色                ✅ yellow → red
P1-13e  线宽滑杆会作用于选中对象                ✅
```
