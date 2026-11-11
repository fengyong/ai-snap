# probes —— 离屏探针（回归用）

这里的探针**链接真实的源码**（不是复刻逻辑），所以它们既是"当初为什么这么定参数"的
证据，也是可以随时重跑的回归检查。

```bash
./probes/run_all.sh              # 全部（不含会碰屏幕录制权限的那个，见下）
./probes/run_all.sh redaction    # 只跑名字里含 redaction 的
```

每个探针都在临时目录里编译（顶层代码那份必须叫 `main.swift`，`swiftc` 才认），
所以互不干扰，也不会往仓库里丢编译产物。

探针**默认并行跑**（并行度按核数，上限 6；`AISNAP_PROBE_JOBS=4` 可覆盖）——
每份探针的可执行文件**用它自己的名字**，于是 `UserDefaults.standard` 的域
也是它自己的（macOS 对「没有 bundle 的裸可执行文件」用进程名当域），
探针之间不共用偏好文件，可以安全并行。全量跑一遍约 **2 分钟**（串行约 7 分钟）。

## ⚠️ 有一条会碰系统权限，所以默认不跑

任何一次**真实的抓屏请求**（`SCShareableContent` / `CGWindowListCreateImage`）都会让发起
请求的那个二进制被登记进「系统设置 → 隐私与安全性 → **屏幕录制**」列表。

探针每次都在**新的临时路径**里编译，于是：

- 跑一次就**多一条**垃圾记录（显示成 `run` 之类）；
- 这类按路径识别的裸可执行文件 **`tccutil reset` 清不掉**
  （报 `No such bundle identifier`），只能在系统设置里选中那条按 `−` 手动删；
- 2026-09-28 实测踩到过：用户列表里冒出了好几条。

所以默认轮次**完全不发抓屏请求** —— `master_parity_probe` 第 9 节整节跳过、
`permission_probe` 不参与。要验权限逻辑时显式打开：

```bash
AISNAP_PROBE_ALLOW_CAPTURE=1 ./probes/run_all.sh permission
AISNAP_PROBE_ALLOW_CAPTURE=1 ./probes/run_all.sh master_parity
```

跑完记得去系统设置里把新出现的条目删掉。

## 另一个副作用：Dock 里的 `run` 图标（已修）

`AnnotationWindow.setupMainMenu` 会把激活策略切成 `.regular`（真应用要靠它露出菜单栏、
进 Dock 与 ⌘Tab）。裸可执行文件（探针都叫 `run`）默认策略是 `.prohibited`，所以以前
**每跑一个构造标注窗的探针，Dock 里就蹦出一个 `run` 图标**、还会抢走前台焦点。

现在只在 `NSApp.delegate is AppDelegate` 时才切 —— 真应用的入口 `main.swift` 会设
delegate，探针不会。两条不变式都有断言守着（`postfix_probe` 第 4 节：装 delegate 时
必须切成 `.regular`、不装时必须不进 Dock）。

另外 `run_all.sh` 加了 `trap ... RETURN`：脚本被 Ctrl-C 或超时杀掉时也会清掉编译目录
（实测漏过一次，`$TMPDIR` 里留下 5 个探针目录）。

## 为什么值得单独一个目录

- **参数都有据可查**：dash 长度、圆角半径、马赛克块大小与插值质量、每帧成本上限，
  这些数不是"感觉合适"，而是实测出来的。改代码后跑一遍就知道有没有把结论推翻。
- **覆盖"静默做错事"的地方**：不崩、不报错、只是结果不对的逻辑（坐标方向、
  版本号比较、撤销粒度）最值得抽成纯函数 + 探针。

相关的坑与手法见技能 `~/.workbuddy/skills/appkit-offscreen-verify/`。

## 清单

| 探针 | 被测内容 | 断言数 |
|---|---|---|
| `prefs_probe` | 偏好持久化：脏数据回退、颜色互转 | 33 |
| `hotkey_probe` | 快捷键：展示顺序、合法性校验、系统截图黑名单 | 29 |
| `hotkey_ignore_probe` | 全局快捷键的应用忽略列表 | 全部通过 |
| `cyclic_index_probe` | Tab 循环的下标回绕（负数取模） | 14 |
| `text_shape_probe` | 文字标注几何 + 周长参数互逆性 | 22 |
| `screen_geometry_probe` | 屏幕/图像坐标换算（含与真实显示器布局交叉验证） | 13 |
| `window_pick_probe` | 窗口挑选：Quartz→AppKit 矩形翻转、标题拼接、滚轮换选回绕 | 22 |
| `export_encode_probe` | 导出编码：PNG 逐位一致、JPEG/HEIC 魔数（硬件不支持时如实跳过）；**O8 编码单源化**：两条入口字节一致 + 贴图旧路径与新路径**像素/alpha 逐像素一致**（透明边缘不许变） | 18 |
| `anchored_placement_probe` | 标注窗口按选区锚定摆放 | 23 |
| `overlay_style_probe` | 冻结覆盖层的外观 | 10 |
| `toolbar_layout_probe` | 工具栏分组布局与折行 | 33 |
| `toolbar_width_probe` | 工具栏单行宽度上限（屏宽取窗口所在屏，折行上限用固定屏宽断言） | 16 |
| `redaction_probe` | 打码：块平均、硬边、模糊边缘、隐私抹平、每帧成本、强度按比例 | 37 |
| `downscale_probe` | 降采样实现横向对比（CG 各插值档 / 手写平均 / vImage） | 判据式 |
| `history_probe` | 截图历史：索引与磁盘同步、自愈、损坏降级 | 29 |
| `update_probe` | 更新检查：版本号比较（1.10.0 > 1.9.0）、清单地址校验 | 54 |
| `eraser_probe` | 橡皮擦：整笔一步撤销、级联删除箭头（合成鼠标事件） | 22 |
| `picker_probe` | 取色器：Y 翻转方向、倍率反推、放大镜切片 | 28 |
| `ocr_probe` | OCR：归一化框 → 画布的**无翻转**换算、阅读顺序（真跑 Vision） | 20 |
| `settings_scroll_probe` | 设置窗口滚动容器（E06）：钳高可滚、翻转停在顶部、窗口复用语义；**屏高注入**（O2：断言不再依赖本机屏幕） | 29（多屏机器 §4 多 3 条） |
| `postfix_probe` | 第一轮复核 13 项修复的回归（整模块 + 真实窗口） | 80 |
| `master_parity_probe` | A 区分叉缺失项在 master 上的重新实现：箭头几何（含对照）、导出像素、restyle 撤销/重做、窗口挑选、命中层隔离、线宽能力协议、**O14 变换能力子协议**（旋转/平移/周长/手柄） | 113（第 9 节需 `AISNAP_PROBE_ALLOW_CAPTURE=1`，另 +2） |
| `freehand_probe` | 自由画笔/马克笔：过采样点、双图层命中、质心锚定的缩放移动 | 16 |
| `magnifier_probe` | 放大镜：取样位置（Y 翻转）/ 拖动重取样 / 命中 / 缩放下限 | 11 |
| `stitch_scroll_probe` | 滚动长截图拼接算法 spike：偏移识别 / 接缝连续 / nil 边界 / 性能预算 | 11 |
| `snap_priority_probe` | 吸附优先：落笔 vs 移动的优先级（吸附指示不许成谎言） | 14 |
| `selection_adjust_probe` | 选区可调整态（两步语义）：松手不立即确认、移动/缩放/重选、Enter（小键盘 76）/双击确认、Esc 取消 | 38 |
| `resize_handle_probe` | 矩形族边/角手柄：单维调整、对边锚定、Esc 还原、下限 | 20 |
| `resize_drag_probe` | 手柄**多事件**拖拽：中心不得二次累加（单事件探针测不出） | 12 |
| `resize_undo_probe` | `.resize` / `.scale` / `.move` 撤销是否完整还原（尺寸**与位置**） | 26 |
| `text_undo_probe` | 文字标注撤销：创建态首编 ⌘Z 是否留下隐形空对象 | 12 |
| `export_perf_probe` | 导出路径成本拆解（P2-8 量化基准） | 对比探针 |
| `pin_lifetime_probe` | 贴图窗口生命周期：close 之后窗口是否真被释放 | 5 |
| `window_lifetime_probe` | 标注窗 / OCR 面板生命周期：close 之后窗口是否真被释放 | 7 |
| `ocr_order_probe` | OCR 面板：显示顺序 ↔ 区间 ↔ 识别框必须同源 | 11 |
| `redaction_preview_probe` | 打码预览与最终对象必须画在同一块地方（像素实测） | 6 |
| `fingerprint_probe` | 形状状态指纹（O11）：逐字段「改了必须变」+ 反向「不该变的不变」+ 画布级未送出判定 | 74 |
| `undo_pairing_probe` | 撤销栈配对不变量（O12 步骤 0）：正向变更清 redo / 撤销只追加 / 重做不清 redo（10 个正向变更写点逐类） | 111 |
| `permission_probe` | 权限判定：**无权限时不得判成有权限**。用 launchctl 另起一个无 TCC 授权的自己来验 | 2 ~ 5（视环境）**默认不跑** |

> **断言数怎么校**：跑一遍 `./probes/run_all.sh`，每份探针的汇总行就是它的断言数
> （`通过 N 项，失败 M 项`；老探针只印「全部通过」，数字见上表）。
> 数字漂了就照实改这张表 —— **表里写的数要能对着跑出来的结果**。

### 已知红灯（`run_all.sh` 的 `EXPECTED_FAIL`）

**当前无已知红灯** —— `run_all.sh` 的 `EXPECTED_FAIL` 是空数组，默认轮次应当全绿。

机制保留：清单里的探针**照样注册**为常驻回归（红灯本身就在盯那个行为，
等修复落地那一刻它会自己转绿，比事后补测试可靠）；但**对应批次落地后必须删条目** ——
`run_all.sh` 在探针意外转绿时会报错并要求从 `EXPECTED_FAIL` 删掉对应条目，
免得「已知红灯」变成吞掉回归的遮羞布。

> **2026-11-11 更新**：下面三条曾经常驻红灯，现已全部修复、清单已清空 ——
> 留着这张表是为了记下「它们盯的是什么」，**不是**「它们现在还红着」：
>
> | 探针 | 曾经红的断言 | 修复提交 |
> |---|---|---|
> | `resize_undo_probe` | §6 `.scale` 撤销在下限处过冲 | `4986858`（批次 3 / P1-1） |
> | `text_undo_probe` | §1 创建态首编 ⌘Z 留下隐形空对象 | `e7c7206`（批次 3 / P1-2） |
> | `pin_lifetime_probe` | §1 关闭后窗口仍被 `NSApp.windows` 留住 | `25ff3c7`（批次 4 / P1-6） |

`legacy/` 是更早期的一次性验证脚本（自带实现、不依赖仓库源码），保留作历史记录，
不参与 `run_all.sh`。

## 加一个探针

1. 新建 `probes/<名字>_probe.swift`，用顶层代码写断言，末尾 `exit(失败数 == 0 ? 0 : 1)`
2. 在 `run_all.sh` 里加一行 `run_probe <名字>_probe <需要链接的源文件...>`
   - 只链真正需要的文件 —— 这样"这个探针依赖哪些模块"在脚本里一眼可见
   - 需要构造真实 `NSView` / 合成 `NSEvent` 的，用 `${ALL_SOURCES[@]}` 整模块链
3. 探针里写清楚**为什么需要它**（有几处错了不会报错），以及断言依据从哪来

## 加一个形状　**（O11 之后的硬约定，别绕过）**

1. **conform `AnnotationObject`** —— 它要求实现 `stateFingerprint`，且**没有默认实现**：
   新形状不表态就**编译不过**。这是有意的（同 `pointOnPerimeter` / `perimeterParameter`
   的既有范式）—— 给了默认值，新形状就会静默继承一份"只覆盖通用字段"的指纹。
2. **必须同时向 `fingerprint_probe §1` 追加逐字段断言**：改那个字段 → 指纹必须变。
   **编译器只能强制「表态」，不能强制「覆盖完整」** —— 这是 O11 剩下的最后一个手工不变量，
   只能靠这条规矩 + 下面第 3 条兜住。
3. **`stateFingerprint` 必须覆盖该形状的全部可变存储字段**（几何 + 样式 + 类型特有字段）。
   `commonStateFingerprint()` 是**基底**，不是全部 —— 只调基底就收工，是本仓库唯一的反面教材：
   那样改这个形状的线宽，指纹不变，"未送出的改动"就永远看不见。
   - 顺带排除**环境字段**：`sourceImage` / `pixelScale` **不算**用户状态
     （它们是画布注入的底图上下文，同一会话内不变）—— 算进去会因重新取样而
     指纹持续变化，表现为**关窗前反复误提醒**。
     这条由 `fingerprint_probe §4` 的反方向断言钉住。
4. 若形状有线宽，还要 conform `LineWidthSupporting`（O7）—— 否则「改线宽」对它无效，
   而漏改不报错，只是用户看到"选了却改不动"。
