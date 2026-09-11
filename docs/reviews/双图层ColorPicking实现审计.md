# 双图层 Color Picking 实现审计（对照业界正确做法）

> 审计对象：`HitTestBuffer.swift`（128 行）+ `AnnotationView.swift` / `Models.swift` 中 Layer A/B 相关路径
> 审计方法：源码逐条对照业界 picking buffer 已知坑清单 + 可复现实验（脚本 `pick_audit.swift`，与 `HitTestBuffer` 完全相同的上下文参数逐字节实测）
> 审计日期：2026-09-11

---

## 一、总裁定

**实现正确。** 业界 picking buffer 的 7 大已知坑，AISnap 踩对 5 项、1 项实测排除（理论上成立但实际未发生）、1 项为性能问题而非正确性问题。另发现 **1 个此前没人注意到的视觉缺陷**（虚线样式实为实线）。

---

## 二、逐项对照结果

### 2.1 ✅ 正确且对齐业界（12 项）

| # | 业界正确做法 | AISnap 实现 | 证据 |
|---|-------------|------------|------|
| 1 | picking pass 关抗锯齿，杜绝边缘混色 ID | `HitTestBuffer.init`：`setShouldAntialias(false)` + `setAllowsAntialiasing(false)` | **实测**：描边整列扫描 0 个中间色像素，"非此即彼"性质成立 |
| 2 | ID 色必须不透明 | `colorFromKey` 恒 `alpha: 1.0`；所有 `drawHitTest` 用不透明色 | 实测 Z 序覆盖读回精确顶层 key |
| 3 | 关 blending（或等价：不透明 source-over） | 未显式设 blend mode，但因 ID 色不透明，source-over 语义等价于完全覆盖 | 实测通过 |
| 4 | 只读必要像素，不做全缓冲回读 | `pickColorKey` 直接指针读 4 字节（`HitTestBuffer.swift:52-71`） | 优于 GPU 方案（无回读开销），且 `bytesPerRow` 取自 context 实际值，稳健 |
| 5 | 颜色空间不受色彩管理介入 | 缓冲区 `CGColorSpaceCreateDeviceRGB` + `premultipliedLast` | 见 2.3 实测排除项 |
| 6 | 命中区加 slop（加粗） | `drawHitTest` 全部 `lineWidth + 6` | 业界标准做法 |
| 7 | 旋转/缩放由光栅化自动正确 | `drawHitTest` 内 `saveGState` → translate/rotate → restore | **实测**：π/6 旋转描边 key 逐字节保真；AA 设置跨 save/restore 存活 |
| 8 | Y 轴翻转（内存行序 vs 绘图坐标） | `flippedY = height - 1 - y` | **实测**：绘图 y=0（底）↔ 读图 y=0（底），正确 |
| 9 | key 0 保留给背景且不可碰撞 | 背景填黑、key 从 1 起、24bit 上限回绕 | 黑/白是任意色彩转换的不动点，背景永不误判 |
| 10 | 新增对象增量绘制、结构性变化全量重绘 | add → `drawObject`（增量，追加在 Z 序顶）；delete/undo/move → `redrawAll` | 语义正确（性能见 2.5） |
| 11 | 空心形状命中可穿透内部 | 矩形/椭圆 Layer B 仅描边 | DESIGN.md 有意设计，文档与实现一致 |
| 12 | 参数化约束可安全穿越 Undo/Redo | 附着存 `Attachment(perimeter: parameter)` 而非绝对坐标 | 与业界约束系统同构，undo 旋转父对象后箭头自动重算 |

### 2.2 🟡 新发现：虚线箭头样式实际渲染为实线（视觉缺陷）

**这是本次审计唯一的正确性级新发现**，来源是实验 3 的反常结果（预期虚线有命中空洞，实测 0/240）：

- `Arrow.drawArrow`（`Models.swift:334-357`）先设 `setLineCap(.round)` 再设 `setLineDash([8,4])`。
- round cap 让每段 dash 两端各延伸 `lineWidth/2`，实覆盖 = `8 + lineWidth`，周期 12。
- **当 lineWidth ≥ 4 时（默认 15px），间隙被完全吞掉——"虚线/点菱"两种预设画出来和实线没有区别。**
- 讽刺的副作用：Layer B 命中区也因同样原因**没有**虚线空洞（对 picking 反而是好事），但这是巧合不是设计。

**修复建议**（两处一起改，避免修了视觉反而制造命中空洞）：
1. 视觉层：dash 长度按线宽比例缩放（业界惯例 `[3w, 2w]`），虚线用 `.butt` cap；
2. picking 层：`drawHitTest` 强制实线（`setLineDash([])`）——业界标准是 picking pass 永不继承视觉 dash。

### 2.3 🔵 理论风险，实测排除：Generic → Device RGB 的 key 保真

`colorFromKey` 用 `NSColor(red:green:blue:)`（**Generic/Calibrated RGB 空间**）生成 ID 色，画进 **DeviceRGB** 位图理论上要经色彩空间转换——若某分量偏移 ±1，字典查找即静默失效（命中检测整体失灵）。

**实测结论：18 个代表性 key（含 1、5、255、0x010101、0xFFFFFF 等边界值）填充后全部逐字节保真，转换未发生偏移。** 当前代码可安全工作。

**加固建议**（一行改动，消除对转换行为的依赖）：ID 色直接在缓冲区自身的 color space 里构造——
`CGColor(colorSpace: context.colorSpace!, components: [r, g, b, 1.0])`，把"恰好正确"变成"构造性正确"。

### 2.4 ✅ 实验记录摘要

| 实验 | 结果 |
|------|------|
| 1. 18 个 key 纯色填充保真 | ✅ 全部逐字节一致 |
| 2. 描边中心 + 整列中间色扫描 | ✅ key 精确，0 混色像素 |
| 3. 虚线轴线采样（240 点） | ⚠️ 0 空洞 → 暴露 2.2 的视觉缺陷 |
| 4. Z 序覆盖 | ✅ 顶层 key 精确读回 |
| 5. Y 翻转 | ✅ 正确 |
| 6. saveGState/rotate 下 key 保真 | ✅ 正确 |

### 2.5 ⚠️ 性能偏差（非正确性）：拖拽时全量重绘

每次 `mouseDragged` 调 `redrawAll`（清空 + 按 Z 序重绘全部，`AnnotationView.swift:213/225/243`）。对象 ≤ 50 无感，数百对象掉帧。业界解法按成本从低到高：

1. 只重绘受影响对象：移动时清掉该对象旧 footprint（含 +slop 边距），重绘 Z 序受影响区间——命中语义不变；
2. 脏矩形裁剪：`ctx.clip(to: dirtyRect)` 后照常重绘，光栅化自动跳过区外；
3. 双缓冲 picking（持续渲染场景时的做法，本场景用不上）。

### 2.6 ℹ️ 备忘（无需行动）

- key 回绕（>1677 万对象后复用）：单次标注会话不可达；
- Layer B 为 1x 逻辑分辨率：命中精度 1pt，+6pt slop 完全覆盖 Retina 半点误差；
- `Int(point.x)` 截断而非四舍五入：slop 之下无感知；
- 红色 X 删除按钮用几何判定而非 Layer B：UI 部件与画布对象分离，业界同款混搭，正确。

---

## 三、结论

双图层方案在 AISnap 中的落地是**教科书级正确**的：业界 7 大坑要么已被规避、要么经实测排除。需要动手的只有三件事，按优先级：

1. 修虚线样式（2.2，含 picking pass 强制实线）——正确性级
2. `drawHitTest` 强制实线 + ID 色改 DeviceRGB 构造（2.3 加固）——防御性
3. 拖拽增量重绘（2.5）——做贴图/大量对象之前必须还

---

## 附：审计脚本

`pick_audit.swift`（与本文同目录）：以与 `HitTestBuffer` 完全一致的参数（DeviceRGB、premultipliedLast、关 AA、相同 colorFromKey/pickColorKey 逻辑）构建离屏上下文，6 组实验全部可独立复现。运行：`swift pick_audit.swift`
