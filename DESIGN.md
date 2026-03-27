# AISnap 设计文档

macOS 截图标注工具，支持区域截图、窗口截图，以及在截图上绘制可移动、可旋转、可缩放的多种标注对象（箭头、矩形、圆形、符号、表情等）。

---

## 1. 系统概览

```
┌─────────────────────────────────────────────────────┐
│                   macOS 菜单栏                        │
│              ┌──────────────────┐                     │
│              │  📷 AISnap 图标   │                    │
│              │  ├─ 区域截图       │                    │
│              │  ├─ 窗口截图       │                    │
│              │  └─ 退出          │                     │
│              └──────────────────┘                     │
└──────────────────────┬──────────────────────────────┘
                       │ 用户选择截图方式
                       ▼
          ┌────────────────────────┐
          │     截图捕获阶段        │
          │  区域: 全屏覆盖层选区    │
          │  窗口: 检测鼠标下方窗口  │
          └────────────┬───────────┘
                       │ CGImage
                       ▼
          ┌────────────────────────┐
          │     标注编辑阶段        │
          │  AnnotationWindow      │
          │  ┌──────────────────┐  │
          │  │ AnnotationView   │  │
          │  │ (画布 + 双图层)   │  │
          │  ├──────────────────┤  │
          │  │ 工具栏            │  │
          │  │ [颜色] [保存] [复制]│ │
          │  └──────────────────┘  │
          └────────────────────────┘
```

### 技术栈

| 项目     | 选型                   |
|----------|----------------------|
| 语言     | Swift 5.9            |
| UI 框架  | AppKit (NSView/NSWindow) |
| 构建系统 | Swift Package Manager |
| 最低版本 | macOS 13 (Ventura)   |
| 截图 API | CGWindowListCreateImage |

选择 AppKit 而非 SwiftUI 的原因:
- 需要精确控制鼠标事件 (mouseDown/mouseDragged/mouseUp)
- 需要直接操作 CGContext 进行像素级渲染
- 需要创建特殊窗口类型 (无边框全屏覆盖层)
- SwiftUI 在这类底层图形交互场景中控制力不足

---

## 2. 项目结构

```
ai-snap/
├── Package.swift                       # SPM 配置
└── Sources/
    ├── main.swift                      # 应用入口
    ├── AppDelegate.swift               # 应用生命周期 + 菜单栏
    ├── Models.swift                    # 数据模型 (Arrow, CanvasState)
    ├── HitTestBuffer.swift             # 隐藏图层 (Layer B) 实现
    ├── ScreenCapture.swift             # 屏幕捕获 (区域/窗口)
    ├── RegionSelectionWindow.swift     # 全屏覆盖选区窗口
    ├── AnnotationView.swift            # 标注画布 (核心)
    └── AnnotationWindow.swift          # 标注窗口 + 工具栏
```

### 模块职责

| 文件 | 职责 | 依赖 |
|------|------|------|
| `main.swift` | NSApplication 启动引导 | AppDelegate |
| `AppDelegate` | 菜单栏图标、截图流程调度 | RegionSelectionWindow, ScreenCapture, AnnotationWindow |
| `Models` | AnnotationObject 协议、Arrow/Rectangle/Circle/Stamp 类、状态枚举 | 无 |
| `HitTestBuffer` | 离屏位图缓冲区，Color Picking 命中检测，调试可视化 | Models |
| `ScreenCapture` | CGWindowList API 封装 | 无 |
| `RegionSelectionWindow` | 全屏半透明覆盖层 + 拖拽选区 | ScreenCapture |
| `AnnotationView` | 双图层画布渲染、鼠标交互、多形状绘制/移动 | Models, HitTestBuffer |
| `AnnotationWindow` | 窗口容器、工具栏 (工具/颜色/保存/复制)、调试面板 | AnnotationView |

---

## 3. 核心设计: 双图层 Color Picking

这是本项目的核心架构决策，用于解决"如何判断用户点击了哪个箭头"的命中检测 (Hit Test) 问题。

### 3.1 传统方案 vs 双图层方案

**传统几何计算方案:**
- 遍历所有图形对象，计算鼠标坐标到每个图形的距离
- 每种图形类型 (箭头、矩形、圆形...) 需要独立的几何判定代码
- 复杂度 O(n)，且新增形状时需要编写新的数学逻辑

**双图层 Color Picking 方案 (本项目采用):**
- 维护一个用户不可见的离屏缓冲区
- 每个图形在离屏缓冲区中用唯一颜色绘制
- 命中检测 = 读取一个像素 + 一次 Map 查找
- 复杂度 O(1)，新增形状时零额外代码

### 3.2 三层架构

```
┌────────────────────────────────────────────┐
│              用户可见                        │
│  ┌──────────────────────────────────────┐  │
│  │         Layer A (显示层)              │  │
│  │  ┌────────────────────────────────┐  │  │
│  │  │       Layer O (原始截图)        │  │  │
│  │  │                                │  │  │
│  │  │   + 所有箭头 (用户选择的颜色)    │  │  │
│  │  │   + 选中状态高亮               │  │  │
│  │  │   + 正在绘制的预览箭头          │  │  │
│  │  └────────────────────────────────┘  │  │
│  └──────────────────────────────────────┘  │
│                                            │
│              用户不可见                      │
│  ┌──────────────────────────────────────┐  │
│  │         Layer B (命中检测层)          │  │
│  │                                      │  │
│  │   同样的箭头，但每个箭头使用唯一颜色    │  │
│  │   背景色 = #000000 (无对象)          │  │
│  │   箭头1 = #000001                    │  │
│  │   箭头2 = #000002                    │  │
│  │   ...                               │  │
│  │   抗锯齿: 关闭                       │  │
│  │   线宽: 比 Layer A 粗 6pt (增大选中区) │ │
│  └──────────────────────────────────────┘  │
└────────────────────────────────────────────┘
```

**Layer O** — 原始截图 (NSImage)
- 截图完成后不再修改
- 每次重绘时作为底图绘制到 Layer A

**Layer A** — 用户可见的显示层 (NSView.draw)
- 每帧完整重绘: Layer O + 所有箭头 (用户选择的颜色)
- 包含选中高亮、绘制预览等视觉反馈

**Layer B** — 隐藏的命中检测层 (CGContext 离屏位图)
- 与 Layer A 同尺寸
- 同样的箭头形状，但使用唯一颜色绘制
- **必须关闭抗锯齿**，否则边缘混色导致颜色查找失败
- 线宽比 Layer A 粗 6pt，增大可选中区域

### 3.3 数据结构

```swift
// 箭头存储: Map<唯一颜色Key, Arrow>
var arrows: [UInt32: Arrow] = [:]
```

用 `UInt32` 作为 key，对应 RGB 24 位颜色值 (忽略 Alpha):

```
key = (R << 16) | (G << 8) | B

key 0 = #000000 → 保留给背景，代表"无对象"
key 1 = #000001 → 第 1 个箭头
key 2 = #000002 → 第 2 个箭头
...
key 16777215 = #FFFFFF → 理论上限约 1600 万个对象
```

### 3.4 命中检测流程

```
用户在 Layer A (可见层) 上按下鼠标
    │
    │  获取鼠标坐标 (x, y)
    ▼
在 Layer B 的 CGContext 中读取 (x, y) 处的像素
    │
    │  pixel = data[y * bytesPerRow + x * 4]
    │  colorKey = (R << 16) | (G << 8) | B
    ▼
    ┌─────────────────────────────┐
    │  colorKey == 0 ?            │
    │  ├─ 是: 未命中任何对象       │ → 开始绘制新箭头
    │  └─ 否: 在 Map 中查找       │ → 进入移动模式
    └─────────────────────────────┘
```

像素读取直接操作内存指针，无 GPU 回读开销:

```swift
let ptr = data.assumingMemoryBound(to: UInt8.self)
let offset = y * bytesPerRow + x * 4
let r = UInt32(ptr[offset])
let g = UInt32(ptr[offset + 1])
let b = UInt32(ptr[offset + 2])
let colorKey = (r << 16) | (g << 8) | b
```

### 3.5 关键约束: Layer B 必须关闭抗锯齿

```swift
context.setShouldAntialias(false)
context.setAllowsAntialiasing(false)
```

原因: 如果开启抗锯齿，箭头边缘像素会被混合成中间色。例如箭头颜色 `#000001` 和背景 `#000000` 之间会出现 `#000001` 到 `#000000` 的渐变像素，这些中间色在 Map 中不存在对应条目，导致边缘区域无法选中。

关闭抗锯齿后，每个像素非此即彼 — 要么是箭头颜色，要么是背景色。

---

## 4. 箭头数据模型

```swift
struct Arrow {
    let id: UUID                    // 唯一标识
    var startPoint: CGPoint         // 箭尾坐标
    var endPoint: CGPoint           // 箭头坐标
    var color: NSColor              // 用户可见的颜色
    var lineWidth: CGFloat          // 线宽 (默认 3.0)
    let hitTestColorKey: UInt32     // Layer B 中的唯一颜色 key
}
```

绘制方法 `Arrow.draw(in:withColor:lineWidthOverride:)` 同时服务于 Layer A 和 Layer B:
- Layer A 调用: 使用用户选择的颜色
- Layer B 调用: 传入 `overrideColor` 为唯一颜色，`lineWidthOverride` 为加粗线宽

箭头的视觉组成:
1. **箭身**: startPoint → endPoint 的直线段
2. **箭头**: endPoint 处的三角形 (张角 30 度，长度 14pt)

---

## 5. 状态机

画布交互使用三状态状态机:

```
                    点击空白区域
        ┌──────────────────────────────┐
        │                              ▼
    ┌───────┐   点击已有箭头      ┌──────────┐
    │ idle  │ ────────────────► │ moving   │
    │       │                   │          │
    │       │   拖拽             │ 拖拽: 更新箭头位置 + 重绘 A/B
    │       │                   │          │
    └───────┘                   └─────┬────┘
        ▲                             │
        │        mouseUp              │
        │◄────────────────────────────┘
        │
        │   点击空白区域
        ▼
    ┌──────────┐
    │ drawing  │
    │          │
    │ 拖拽: 预览新箭头
    │          │
    └─────┬────┘
          │ mouseUp (长度 > 5pt)
          │ → 创建 Arrow 对象
          │ → 写入 Map
          │ → 绘制到 Layer B
          ▼
      ┌───────┐
      │ idle  │
      └───────┘
```

```swift
enum CanvasState {
    case idle
    case drawing(start: CGPoint)
    case moving(colorKey: UInt32, grabOffset: CGVector)
}
```

### 5.1 moving 状态中的 grabOffset

移动箭头时记录 `grabOffset` (鼠标按下位置相对箭头中心的偏移量)，移动过程中始终保持这个偏移。

作用: 避免箭头"跳到"鼠标位置。箭头从鼠标按下的位置平滑跟随移动。

```
鼠标按下时:
    center = (startPoint + endPoint) / 2
    grabOffset = mousePosition - center

鼠标拖动时:
    newCenter = mousePosition - grabOffset
    delta = newCenter - oldCenter
    startPoint += delta
    endPoint += delta
```

---

## 6. 截图捕获

### 6.1 区域截图流程

```
用户点击"区域截图"
    │
    ▼
创建 RegionSelectionWindow
    │  - 全屏无边框窗口
    │  - 半透明黑色背景 (30% 不透明度)
    │  - 窗口层级: statusBar + 1
    │  - 鼠标指针切换为十字光标
    ▼
用户拖拽选区
    │  - 绘制白色虚线选区边框
    │  - 选区内部使用 blendMode(.clear) 清除遮罩
    │  - 用户可见选区内的原始屏幕内容
    ▼
用户释放鼠标 (选区 > 5x5 px)
    │  - NSView 坐标 → CGWindowList 屏幕坐标 (Y 轴翻转)
    │  - 关闭覆盖窗口
    │  - 延迟 100ms 确保窗口消失
    ▼
CGWindowListCreateImage(captureRect, .optionOnScreenBelowWindow, ...)
    │
    ▼
打开 AnnotationWindow 进入标注阶段
```

按 Escape 键可取消区域选择。

### 6.2 窗口截图流程

```
用户点击"窗口截图"
    │
    ▼
延迟 500ms (给用户切换窗口的时间)
    │
    ▼
CGWindowListCopyWindowInfo 获取所有可见窗口
    │
    ▼
遍历窗口列表 (按 Z 序，最前面的优先)
    │  - 跳过自身进程的窗口
    │  - 获取窗口 bounds
    │  - NSEvent.mouseLocation → 屏幕坐标 (Y 轴翻转)
    │  - 检测鼠标是否在窗口 bounds 内
    ▼
找到目标窗口 → CGWindowListCreateImage(.optionIncludingWindow, windowID, ...)
    │
    ▼
打开 AnnotationWindow 进入标注阶段
```

### 6.3 坐标系说明

macOS 存在两套坐标系:
- **AppKit (NSView/NSEvent)**: 原点在左下角，Y 轴向上
- **Core Graphics (CGWindowList)**: 原点在左上角，Y 轴向下

转换公式: `cgY = screenHeight - nsY - rectHeight`

---

## 7. 标注窗口

### 7.1 窗口布局

```
┌──────────────────────────────────────┐
│  AISnap - 标注                    ─ □ ✕│  ← 标题栏
├──────────────────────────────────────┤
│                                      │
│                                      │
│          AnnotationView              │
│          (截图 + 箭头标注)            │
│          宽高 = 截图尺寸              │
│                                      │
│                                      │
├──────────────────────────────────────┤
│  🔴 🔵 🟢 🟡     [保存] [复制]        │  ← 工具栏 (44pt 高)
└──────────────────────────────────────┘
```

### 7.2 工具栏功能

| 控件 | 功能 |
|------|------|
| 颜色按钮 (红/蓝/绿/黄) | 切换后续箭头的绘制颜色 |
| 保存 | NSSavePanel → 导出 PNG |
| 复制 | 合成图片 → 写入系统剪贴板 |

### 7.3 导出合成

导出时调用 `AnnotationView.compositeImage()`:
1. 创建新的 NSImage
2. 绘制 Layer O (原始截图)
3. 遍历 Map 绘制所有箭头 (用户颜色)
4. 返回合成后的 NSImage

Layer B (命中检测层) 不参与导出。

---

## 8. 渲染管线

每次 `needsDisplay = true` 触发的 `draw(_:)` 调用:

```
Layer A 渲染顺序 (NSView.draw):
    │
    ├─ 1. 绘制 Layer O (baseImage)
    │     └─ NSImage.draw(in: imageRect)
    │
    ├─ 2. 遍历 arrows Map，逐个绘制箭头
    │     ├─ Arrow.draw(in: ctx)              ← 用户选择的颜色
    │     └─ if selected: drawSelectionHandles ← 蓝色圆形端点手柄
    │
    └─ 3. if state == .drawing:
          └─ 绘制预览箭头 (当前拖拽中的新箭头)
```

Layer B 在以下时机重绘:
- 新箭头创建后: `hitTestBuffer.drawArrow(arrow)` (增量)
- 箭头移动后: `hitTestBuffer.redrawAll(arrows:)` (全量)
- 箭头删除后: `hitTestBuffer.redrawAll(arrows:)` (全量)

性能说明: 截图标注场景中箭头数量通常 < 20 个，全量重绘无性能问题。

---

## 9. 键盘交互

| 按键 | 场景 | 行为 |
|------|------|------|
| Escape | 区域选择阶段 | 取消选区，关闭覆盖窗口 |
| Delete / Forward Delete | 标注阶段，有选中箭头 | 从 Map 中删除箭头，重绘 A/B |

---

## 10. 权限要求

应用需要 **屏幕录制** 权限才能正常截图:

- 位置: 系统设置 → 隐私与安全 → 屏幕录制
- 首次调用 `CGWindowListCreateImage` 时系统会弹出授权请求
- 未授权时截图结果为空白图片

---

## 11. 构建与运行

```bash
# 构建
swift build

# 运行
swift run AISnap

# Release 构建
swift build -c release
```

运行后应用以菜单栏图标形式存在 (无 Dock 图标)，通过 `NSApp.setActivationPolicy(.accessory)` 实现。

---

## 12. 扩展性分析

双图层 Color Picking 方案的最大优势是扩展成本极低:

| 新增图形类型 | 需要做的事 |
|-------------|-----------|
| 矩形 | 1. 新增 Rectangle 模型 2. 实现 draw 方法 3. 画到 Layer A 和 B 上 |
| 圆形 | 同上 |
| 文字框 | 同上 |
| 自由画笔 | 同上 |

所有图形类型共享同一套命中检测逻辑 — 读像素 + Map 查找，**无需编写任何新的几何计算代码**。

Map 的 key 空间 (24 位 RGB = 约 1600 万种颜色) 对标注工具而言完全够用。

---

## 13. Layer B 调试可视化

### 13.1 问题: Layer B 肉眼不可见

Layer B 的颜色编码方式决定了它在视觉上几乎全黑:

```
对象 1 → #000001  (R=0, G=0, B=1)
对象 2 → #000002  (R=0, G=0, B=2)
对象 3 → #000003  (R=0, G=0, B=3)
...
```

这些颜色的亮度差异仅 1/255，人眼完全无法区分。直接截图查看 Layer B，看到的就是一张纯黑的图。

这在开发和调试时是一个障碍 -- 你无法直观验证:
- Layer B 上的形状是否和 Layer A 对齐？
- 关闭抗锯齿后的边缘是否干净？
- 加粗 6pt 后的选中区域是否合理？
- 旋转后的形状在 Layer B 中是否正确？

### 13.2 解决方案: 色相放大可视化

核心思路: **用相同的 `drawHitTest()` 方法重新绘制一遍 Layer B 的内容，但将每个对象的颜色映射到人眼可区分的明亮色彩。**

这样展示的是 Layer B 的**真实形状、真实线宽、真实抗锯齿设置**，唯一不同的是颜色被放大到可视范围。

```
┌─────────────────────────────┐
│     调试可视化生成流程        │
│                             │
│  1. 创建新 NSImage          │
│  2. 关闭抗锯齿 (模拟 Layer B)│
│  3. 填充深色背景 (#1A1A1A)   │
│  4. 遍历 zOrder:            │
│     │  对象 i →             │
│     │  色相 = i * 黄金比例   │
│     │  obj.drawHitTest(亮色) │
│  5. 返回可视化图像           │
└─────────────────────────────┘
```

### 13.3 黄金比例色相分配

使用黄金比例 (0.618034...) 作为色相步进值，可以保证无论对象数量多少，相邻对象的颜色差异始终最大化:

```
对象 1: hue = 1 * 0.618 = 0.618  (偏蓝)
对象 2: hue = 2 * 0.618 = 0.236  (偏黄绿)
对象 3: hue = 3 * 0.618 = 0.854  (偏紫)
对象 4: hue = 4 * 0.618 = 0.472  (偏青)
...
```

这比等间距分配 (1/n) 更好，因为:
- 等间距分配在对象数量变化时，所有颜色都会跳变
- 黄金比例是递增的，新增对象不影响已有对象的颜色
- 数学上可证明，黄金比例是最不均匀数 (most irrational number)，色相分布的均匀性最优

### 13.4 另一种思路: 色差放大法

在开发早期阶段使用过另一种方法: 不重新绘制，而是直接将 Layer B 的原始像素进行颜色放大。

```
原始 colorKey → 放大后颜色
#000001      → key * 80 = #000050  (可见的深蓝)
#000002      → key * 80 = #0000A0  (较亮的蓝)
#000003      → key * 80 = #0000F0  (明亮的蓝)
```

优点: 直接操作像素数据，无需重新调用 draw 方法
缺点: 相邻对象的颜色仍然相近 (都在蓝色系)，当对象超过 3-4 个时区分度下降

最终选择黄金比例色相方案，因为它在任意对象数量下都能保持良好的视觉区分度。

### 13.5 窗口布局

调试面板以 50% 缩放显示在标注窗口右侧:

```
┌──────────────────────────────┬─────────────────────┐
│  AISnap - 标注                │                     │
├──────────────────────────────┤ Layer B (命中检测层)  │
│                              │                     │
│                              │  ┌───────────────┐  │
│      AnnotationView          │  │               │  │
│      (Layer A, 用户操作区)     │  │  50% 缩放预览  │  │
│                              │  │  实时同步      │  │
│                              │  │               │  │
│                              │  └───────────────┘  │
│                              │                     │
├──────────────────────────────┴─────────────────────┤
│  [箭头 矩形 圆形] | [红 蓝 绿 黄] | [保存] [复制]     │
└────────────────────────────────────────────────────┘
```

调试面板在以下时机自动刷新:
1. 创建新对象后 (mouseUp 创建完成)
2. 移动对象后 (mouseDragged 更新位置)
3. 删除对象后 (keyDown 删除)

### 13.6 Layer B 可视化的对比观察

通过左右对比 Layer A 和 Layer B，可以直观验证:

| 观察项 | Layer A (左) | Layer B 可视化 (右) |
|--------|-------------|-------------------|
| 颜色 | 用户选择的颜色 | 每个对象一种亮色 |
| 线宽 | 原始线宽 | 线宽 + 6pt (更粗) |
| 抗锯齿 | 开启 (边缘平滑) | 关闭 (边缘锯齿状) |
| 空心形状 | 只有描边 | 只有描边 (可穿透内部) |
| 实心形状 (表情等) | 渲染图像 | 填充包围矩形 |
| 选中手柄 | 显示蓝色圆点 | 不显示 (纯形状) |
| 预览 | 显示拖拽中的预览 | 不显示 (只有已确认对象) |

### 13.7 为什么旋转不增加 Layer B 的复杂度

传统几何命中检测在处理旋转对象时，需要将鼠标坐标逆变换到对象的局部坐标系:

```
传统方案:
mousePoint → 逆旋转 → 局部坐标 → 几何判定 (每种形状不同)
```

双图层方案中，旋转对象在 Layer B 中直接以旋转后的姿态绘制:

```
双图层方案:
绘制时: CGContext.rotate(by: angle) → drawHitTest()  (形状已旋转)
检测时: 读取 (x, y) 像素 → 完成                      (零额外计算)
```

旋转后的命中区域自动正确，因为它就是像素 -- 不需要任何数学变换。这是双图层方案最精妙的地方: **把几何问题转化为像素问题，让 GPU 的光栅化替你完成所有数学计算。**
