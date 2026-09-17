# AISnap 探针套件（probes）

这里的每个探针都是**对 `Sources/` 里真实源码的可执行验证**：探针不复制、不模拟被测逻辑，
而是把 `Sources/*.swift` 和探针一起编译，用真实的 `NSEvent` / 真实的 `NSWindow` / 真实的
`CGWindowList*` 走生产代码路径，然后把「实测值」和「应有值」并排打印出来。

配套的结论与修复建议见仓库根目录的 `CODE_REVIEW.md`。

## 运行

```bash
./probes/run_all.sh            # 全部探针
./probes/run_all.sh geometry   # 只跑名字里含 geometry 的
```

输出约定：

```
[PASS] <报告编号>  <断言>  — <实测值>       ← 该项符合预期
[FAIL] <报告编号>  <断言>                    ← 复现了报告里列出的缺陷
       实测: ...
       应为: ...
[INFO] <报告编号>  <事实陈述>                ← 随环境变化的量，不作判定
```

结尾会给出汇总表，`复现缺陷数` 就是该探针判定为 FAIL 的条目数。

## 探针对照表

| 探针 | 覆盖的报告条目 |
|------|----------------|
| `probe_deployment_target.sh` | P0-1 `CGWindowListCreateImage` 在 macOS 15 起 obsolete |
| `probe_layout` | P0-2 工具栏溢出/导出按钮不可达、P4-19 切色板压住后续控件 |
| `probe_geometry` | P1-8 椭圆附着数学错误、P1-9 旋转/缩放不更新附着、P4 第 13 条 `pointOnPerimeter` 自检、第 14 条吸附阈值不一致导致松手跳变 |
| `probe_canvas` | §7 命中检测与撤销重做基线、P1-6 Option/Shift 劫持、P1-7 解除附着不可撤销 |
| `probe_spotlight` | P1-4 聚光灯叠加区被重新压暗 |
| `probe_perf` | P1-5 Layer B 调试面板的拖拽开销 |
| `probe_export_scale` | P2-6 逻辑尺寸/导出分辨率在混合 DPI 下算错 |
| `probe_watermark` | P2-1 水印文本不按回车不生效 |
| `probe_screens` | P1-1 Y 翻转锚点、P1-10 窗口挑选无过滤、P1-12 `NSScreen.main` 语义、越界截图的失败模式 |
| `probe_region` | P1-2 副屏覆盖窗口吞掉鼠标、P1-11 选区坐标漏掉屏幕原点 |
| `probe_signing.sh` | P3-3 ad-hoc 签名 / build.sh 架构硬编码 |

## 三类探针的差别（重要）

1. **与会话无关**（任何机器、任何时刻结论都成立）
   `probe_deployment_target` / `probe_layout` / `probe_geometry` / `probe_canvas` /
   `probe_spotlight` / `probe_perf` / `probe_export_scale` / `probe_watermark`。
   这些探针验证的是几何、状态机、布局与渲染，不依赖屏幕内容。

2. **依赖会话状态**（锁屏 / 休眠 / 无交互会话下数值会失真）
   `probe_screens` / `probe_region`。
   代码缺陷本身由 SDK 文档即可判定（例如 `NSScreen.mainScreen` 的注释就是 "Screen with key window"，
   而 `kCGWindowBounds` 的原点定义在「主显示器左上角」），但**偏移多少 pt、挑中哪个窗口、
   哪几个窗口排在列表最前面**都跟当前会话有关。
   如果这些探针是在锁屏/无人操作时运行的（窗口列表里会出现 `loginwindow`、鼠标坐标被固定在屏幕角落），
   请解锁后、把鼠标移到目标显示器上再跑一次对照。

3. **需要「屏幕录制」权限**
   `probe_region` 里比较两次截图内容的部分。未授权时两次都会拿到同一张空白/壁纸图，
   探针会把结果标为 `[INFO]` 而不是 `[PASS]`，避免给出假阳性。

## 实现说明

* 探针不会被 SPM 编译进 App —— `Package.swift` 的 target path 是 `Sources`，`probes/` 在它之外。
* 编译参数里固定了 `-target <arch>-apple-macosx13.0`。这是**必须**的：
  `Sources/ScreenCapture.swift` 使用的 `CGWindowListCreateImage` 在 macOS 15 起被标记为
  unavailable，用更高的部署目标会让探针（以及 App 本身）编译失败。详见报告 P0-1。
* `probes/Support.swift` 是通用设施（断言输出、像素读取、图像哈希、屏幕描述）；
  `probes/CanvasSupport.swift` 是驱动 `AnnotationView` 的合成事件辅助，只有链接了
  `AnnotationView.swift` 的探针才会编译它。
* 新增探针：写一个带 `@main` 的文件，用 `Probe.ok / Probe.bug / Probe.note` 输出，
  结尾调用 `Probe.finish("名字")`；然后在 `run_all.sh` 里加一行 `want <名字> && run_swift_probe <名字> <源文件...>`。

## 一个自我纠错的例子

第一版 `probe_canvas` 报出「撤销/重做不一致」，排查后发现是**探针自己的 bug**：
`selects()` 辅助函数用「在空白处点一下」来清空选中，而在贴纸工具下这一下会真的放下一个贴纸，
污染了撤销栈。改成用 ESC 清空选中之后，撤销/重做 9 步回归全部通过 ——
这和报告 §7 的结论一致。探针本身也需要被怀疑。
