# UI 元素吸附 Spike（2026-09-28）

> 阶段 7 的后半：**只做设计验证，不实现**。窗口级吸附已落地（阶段 7 前半，
> `SelectionSnapping` + 冻结时窗口清单）；本文记录把吸附粒度从「窗口」降到
> 「UI 元素」（按钮/输入框/列表行）的技术路径与代价，实现与否待窗口吸附的
> 实际使用反馈再定。

## 目标体验

Snipaste 免费版即有的能力：框选时不仅能贴到窗口边框，还能贴到窗口内的
控件边界（一个按钮、一张卡片、一行列表），让"截某个控件"不用手对像素。

## 技术路径：Accessibility (AX) API

1. **权限门槛（最大的代价）**：读取其他应用的 UI 树需要**辅助功能**权限
   （系统设置 → 隐私与安全性 → 辅助功能）。用户要多授一次权，而且这个权限
   的隐私敏感性远高于屏幕录制（能读一切应用的内容与按键焦点）。
   - `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`
     请求授权；`CGPreflightScreenCaptureAccess` 式的预检同样存在缓存问题。
2. **取元素树**：`AXUIElementCreateApplication(pid)` →
   `kAXFocusedUIElementAttribute` / 递归 `kAXChildrenAttribute`。
   每个元素 `kAXPositionAttribute`（左上角，全局坐标）+ `kAXSizeAttribute`。
3. **命中策略**：不走递归遍历（大树遍历一次几十毫秒、拖拽帧率扛不住）。
   `AXUIElementCopyElementAtPosition` 直接问"这个全局坐标下是什么元素"，
   拿它的 bounds 当吸附候选 —— 与窗口选择模式的"光标处问一次"同构。
4. **性能**：mouseMoved 节流到 ~30Hz + 移动 <2pt 跳过（窗口选择模式同款）。
   单次 `ElementAtPosition` 实测代价待 spike（预估 1-5ms，可接受）。

## 与现有架构的衔接

- `SelectionSnapping` 的几何决策**原样复用**：候选从「窗口 frame 列表」换成
  「元素 bounds 列表」，阈值单独调（元素更小，8pt 太宽，建议 5pt）。
- 权限闸门仿照 `checkScreenCapturePermission`：fail-closed，未授权时静默
  降级为窗口级吸附（不弹窗打断截图流程，状态栏菜单给一次性引导入口）。
- 偏好：`snapToUIElements`（默认关 —— 有权限代价的功能默认关，与
  「截图历史默认开但可真关」的取舍分开对待）。

## 已知风险

- Electron/浏览器内 web 内容的元素树可能只有整页一个元素（粒度退化到窗口级，
  可接受）；游戏/自绘 UI 完全没有元素树（同上）。
- `ElementAtPosition` 对被冻结覆盖层遮住的坐标返回**覆盖层自己** —— 需要在
  取样时临时 `ignoresMouseEvents = true` 或改用冻结前缓存的窗口列表 + AX 树
  快照（倾向后者：冻结那一刻整棵树都该快照下来，与窗口清单同一时点）。
- AX API 是主线程友好的异步 API（带回调版本），但要小心别在拖拽热路径里
  排队 —— 快照策略顺带解决。

## 结论

技术可行、路径清晰；**决策点在权限性价比**：为"截控件对齐"这一场景新增一个
高敏感权限是否值得，等窗口吸附用起来之后看反馈再定。若做，工作量预估
2-3 天（权限闸门 + 快照 + 探针）。
