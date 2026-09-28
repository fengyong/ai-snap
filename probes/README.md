# probes —— 离屏探针（回归用）

这里的探针**链接真实的源码**（不是复刻逻辑），所以它们既是"当初为什么这么定参数"的
证据，也是可以随时重跑的回归检查。

```bash
./probes/run_all.sh              # 全部（不含会碰屏幕录制权限的那个，见下）
./probes/run_all.sh redaction    # 只跑名字里含 redaction 的
```

每个探针都在临时目录里编译（顶层代码那份必须叫 `main.swift`，`swiftc` 才认），
所以互不干扰，也不会往仓库里丢编译产物。

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
| `anchored_placement_probe` | 标注窗口按选区锚定摆放 | 23 |
| `overlay_style_probe` | 冻结覆盖层的外观 | 10 |
| `toolbar_layout_probe` | 工具栏分组布局与折行 | 33 |
| `toolbar_width_probe` | 工具栏单行宽度上限 | 11 |
| `redaction_probe` | 打码：块平均、硬边、模糊边缘、隐私抹平、每帧成本 | 29 |
| `downscale_probe` | 降采样实现横向对比（CG 各插值档 / 手写平均 / vImage） | 判据式 |
| `history_probe` | 截图历史：索引与磁盘同步、自愈、损坏降级 | 29 |
| `update_probe` | 更新检查：版本号比较（1.10.0 > 1.9.0）、清单地址校验 | 42 |
| `eraser_probe` | 橡皮擦：整笔一步撤销、级联删除箭头（合成鼠标事件） | 22 |
| `picker_probe` | 取色器：Y 翻转方向、倍率反推、放大镜切片 | 28 |
| `ocr_probe` | OCR：归一化框 → 画布的**无翻转**换算、阅读顺序（真跑 Vision） | 19 |
| `postfix_probe` | 第一轮复核 13 项修复的回归（整模块 + 真实窗口） | 78 |
| `master_parity_probe` | A 区分叉缺失项在 master 上的重新实现：箭头几何（含对照）、导出像素、restyle 撤销/重做、窗口挑选、命中层隔离 | 36（第 9 节需 `AISNAP_PROBE_ALLOW_CAPTURE=1`，另 +2） |
| `permission_probe` | 权限判定：**无权限时不得判成有权限**。用 launchctl 另起一个无 TCC 授权的自己来验 | 2 ~ 5（视环境）**默认不跑** |

`legacy/` 是更早期的一次性验证脚本（自带实现、不依赖仓库源码），保留作历史记录，
不参与 `run_all.sh`。

## 加一个探针

1. 新建 `probes/<名字>_probe.swift`，用顶层代码写断言，末尾 `exit(失败数 == 0 ? 0 : 1)`
2. 在 `run_all.sh` 里加一行 `run_probe <名字>_probe <需要链接的源文件...>`
   - 只链真正需要的文件 —— 这样"这个探针依赖哪些模块"在脚本里一眼可见
   - 需要构造真实 `NSView` / 合成 `NSEvent` 的，用 `${ALL_SOURCES[@]}` 整模块链
3. 探针里写清楚**为什么需要它**（有几处错了不会报错），以及断言依据从哪来
