# MiMo-Code 空闲状态持续占用 ~22% CPU —— 排查记录

> 分析对象：小米 MiMo Code（mimocode）CLI `0.1.15`
> 分析时间：2026-10-23
> 平台：macOS 27.0 (26A428) / arm64 (Apple Silicon)
> 结论一句话：**这不是"任务"在跑，是 TUI 首页的动画定时器在跑；关掉动画后 CPU 从 ~22% 降到 ~1%。**

---

## 目录

1. [结论速览](#1-结论速览)
2. [排查方法论](#2-排查方法论)
3. [证据链](#3-证据链)
4. [根因分析](#4-根因分析)
5. [修复与规避](#5-修复与规避)
6. [可复用工具箱](#6-可复用工具箱)
7. [踩坑清单](#7-踩坑清单)
8. [上游仓库现状（存档参考）](#8-上游仓库现状存档参考)

---

## 1. 结论速览

### 1.1 实测数据

| 场景 | 空闲 CPU（占一个核） | 备注 |
|---|---|---|
| `mimo`（TUI，默认） | **21.8% – 24.3%** | 复现问题 |
| `mimo serve`（无头，无 TUI） | **0.4%** | 排除 agent/session/MCP/DB 层 |
| `MIMOCODE_TUI_PLAIN=1` | **2.3%** | 绕过 OpenTUI 渲染层 |
| `animations_enabled: false` | **0.7% – 1.1%** | 精准命中根因 |

> 测量口径：启动后预热 20s，取 `ps -o time=` 的 CPU 时间增量 ÷ 墙钟时间。
> `ps` 自带的 `%CPU` 是**衰减生命周期均值**，不能当瞬时值用（见 [§7](#7-踩坑清单)）。

### 1.2 根因链

```
首页星空/流星动画的常驻定时器（50ms / 80ms / 200ms）
        │  每次 tick 写一次 Solid signal
        ▼
触发整棵组件树重新渲染（root.render）
        │
        ▼
OpenTUI 渲染循环把渲染器设成了 targetFps=60 / maxFps=60
        │  每帧重新绘制 + diff 整屏
        ▼
Zig 原生渲染器（走 debug allocator，分配开销被放大）
        │
        ▼
≈22% 的一个核，与是否有任务完全无关
```

### 1.3 一句话根因

> **动画定时器 → Solid 全量重渲染 → 60fps 原生重绘**，三者叠加。
> 这条链路上没有任何一步与"任务"相关，所以"没任务也烧 CPU"是必然结果。

---

## 2. 排查方法论

整个过程遵循一条原则：**先量化、再定位、后归因**。每一步都设计成能证伪某个假设，而不是"看着像"。

### 2.1 定位进程（ps grep 失效 → lsof 反查）

第一步 `ps aux | grep -i mimo` 返回空。换成 `lsof` 反查打开的文件：

```bash
lsof 2>/dev/null | grep -i mimo | awk '{print $1,$2,$9}' | sort -u
```

输出里出现 `mimo 10476 ola /Users/ola/.mimocode/bin/mimo`，直接拿到 PID、可执行文件路径和数据目录。

> 为什么会漏：那个进程是在我第一条 `ps` 执行**之后**才启动的（日志时间戳 `08:08:50Z` = 本地 16:08:50）。进程不是静态的，结论产生后要复核一次。

### 2.2 量化 CPU（放弃 `%CPU`，改用 `TIME` 增量）

`ps %CPU` 是衰减均值，会把"刚启动时的高峰"和"当前真实值"混在一起。改用 CPU 时间增量：

```bash
t1=$(ps -p $PID -o time= | tr -d ' '); sleep 10
t2=$(ps -p $PID -o time= | tr -d ' ')
# 差值 ÷ 墙钟 = 真实占用率
```

### 2.3 归因（`sample` 抓栈 + 自写解析）

```bash
sample $PID 8 -f /tmp/s.txt
```

`sample` 的输出是**折叠树**，"Total number in stack" 段会把同一采样在每一层重复计数。必须自己解析、只取**叶子帧**（leaf）来统计：

```python
leaf = Counter()
for each frame line:
    leaf[(symbol, lib)] += sample_count
# 剔除阻塞态：ulock_wait / psynch_cvwait / kevent64 / workq_kernreturn
```

### 2.4 排除法（证伪"常见嫌疑"）

在归因之前，先用便宜的观测把常见嫌疑一个个排除，避免陷入盲猜：

| 嫌疑 | 验证手段 | 结果 |
|---|---|---|
| 网络轮询 / 心跳 | `lsof -p PID -i` | 空闲期**无连接** |
| 后台同步 / 写日志 | 日志文件 5 秒字节增量 | **0 字节** |
| GC 压力 | `sample` 里 GC 线程状态 | scavenger 线程**全部阻塞** |
| 文件监听 | `lsof` fd 数量 | 仅 40 个，无大量 watch fd |
| 真正的 agent 任务 | `mimo serve`（无头）对照 | 仅 **0.4%** |

### 2.5 A/B 对照实验（定位到 TUI 层）

既然"无头模式"不烧 CPU，那问题就在 TUI 层。再往下切：

- `MIMOCODE_TUI_PLAIN=1` → 2.3%（绕过 OpenTUI）
- `animations_enabled: false` → 0.7%（只关动画，保留完整 TUI）

**这一步是全案关键**：它把"某个不可名状的 TUI 问题"收敛成"一个具体的、可开关的设置"。

### 2.6 源码反查（从二进制里挖 JS）

`mimo` 是 Bun 单文件可执行程序（100MB，stripped），但 **JS 源码以字符串形式内嵌在二进制里**，可以直接 `strings` 后正则检索：

```bash
strings -a ~/.mimocode/bin/mimo > /tmp/mimo_strings.txt
grep -o -E ".{140}setInterval\(.{140}" /tmp/mimo_strings.txt
```

这一步拿到了：动画组件源码、定时器间隔常量、`animations_enabled` 的读取点、OpenTUI 的 FPS 配置、KV 存储路径。

---

## 3. 证据链

### 3.1 进程画像

| 项 | 值 |
|---|---|
| 可执行文件 | `~/.mimocode/bin/mimo`（100 MB，Bun 单文件程序，stripped） |
| 版本 | 0.1.15（仓库最新 release 也是 v0.1.15） |
| 运行时 | Bun + **OpenTUI**（Zig 原生 dylib，运行时解压到 `$TMPDIR/.9ae51fbad….dylib`）+ **Solid.js** |
| 线程数 | 21（main / JSC scavenger / 3× Heap Helper / 4× JIT Worklist / 10× Bun Pool / HTTP Client / Worker / Wasm Worklist） |
| 常驻内存 | 780 MB – 1.07 GB |
| 数据目录 | `~/.local/share/mimocode/`（`mimocode.db` 已达 **525 MB**） |

### 3.2 线程归因（`sample` 8s）

只有主线程在跑 CPU，其余 20 个线程全部阻塞：

```
 BUSY  THREAD
  983  Thread_...  (DispatchQueue_1: com.apple.main-thread)   ← 全部 CPU 在这
        └ renderer.CliRenderer.render        (Zig dylib)
        └ bufferDrawTextBufferView           (Zig dylib)
        └ rope.Rope(text-buffer-segment.Segment)
        └ heap.debug_allocator.DebugAllocator(...).alloc / .free
```

叶子帧统计（全进程）：

```
__ulock_wait2        36558   ← 阻塞
__psynch_cvwait      29459   ← 阻塞
kevent64             17048   ← 事件循环等待
__workq_kernreturn    6010
…mimo 运行时帧（忙）   ≈1240   ← 约 1.24s CPU / 8s ≈ 15%
```

主线程忙在 **JS → FFI → Zig 渲染器** 这条路径上，而不是任何 I/O。

### 3.3 空闲期的行为观测

| 指标 | 数值 | 含义 |
|---|---|---|
| 日志增长 | 0 字节 / 5s | 没有后台同步 |
| 网络连接 | 无 | 没有轮询 |
| 终端输出 | ~200 字节 / 200ms（≈1 KB/s） | 每帧只有几个格子的微更新 |
| 帧内容 | 画面基本不变 | **在重算，但没在变** |

> 注意：用 `OTUI_SHOW_STATS=1` 打开调试 overlay 再测输出速率会得到 **56 KB/s**，那是假的 —— overlay 自己每帧都在变，会强制触发重绘。**不能用带 overlay 的实例测输出速率。**

### 3.4 对照实验矩阵

| 配置 | 12–24s 窗口内的 CPU 时间 | 折算占用率 |
|---|---|---|
| 默认 TUI（动画开） | 2.43s / 12s | **20.3%** |
| 默认 TUI（动画开） | 2.18s / 12s | **21.8%** |
| 默认 TUI（动画开） | 2.43s / 10s | **24.3%** |
| `MIMOCODE_TUI_PLAIN=1` | 0.23s / 10s | **2.3%** |
| `animations_enabled: false` | 0.05s / 12s | **0.4%** |
| `animations_enabled: false` | 0.07–0.11s / 10s（4 段） | **0.7% – 1.1%** |
| `mimo serve`（无头） | 0.04s / 10s | **0.4%** |

---

## 4. 根因分析

### 4.1 动画组件

从二进制里提取到的首页星空组件（变量名已压缩）：

```js
var Hn = ["✦","✧","✦","✧","✦","✧","✦"," "],   // 星点字符集
    LP0 = [...], wP0 = "✶",
    tM = 0.88, MP0 = 200,      // ← 200ms：星点网格刷新间隔
    RP0 = 0.00394, EP0 = 8000,
    IV = 3600, eM = 0.36,
    Qn = 32, NP0 = 50,        // ← 50ms：流星推进间隔
    IP0 = 0.15;

function bV(A = {}) {
  ...
  Z = setInterval(() => { /* 刷新星点网格 */ }, MP0);      // 200ms
  Y = setInterval(() => { /* 生成流星 */ }, MP0);          // 200ms
  X = setInterval(() => {
      G(g => g + 1);                                      // ← 写 Solid signal
      ...
  }, NP0);                                                // 50ms
}
```

同时还有 spinner 帧动画：`qM = { dots: { interval: 80, frames: [...] }, dots2: { interval: 80, ... } }`。

**三个定时器（50 / 80 / 200ms）全程常驻**，每一个 tick 都会写一次 Solid signal。

### 4.2 Solid 全量重渲染的放大效应

Solid 的 signal 写入会触发依赖它的计算单元重算。首页这些动画信号被大量组件订阅，因此一次 50ms 的 signal 写入会引发**整棵组件树重新渲染**，而不是只更新那个流星字符。

### 4.3 OpenTUI 的 60fps 循环

mimo 在构造渲染器时写死了帧率：

```js
function OB2(A, D) {
  return {
    targetFps: D ? 10 : 60,      // ← 正常 TUI 模式 = 60
    ...
    ...(D ? { maxFps: 15, ... } : { maxFps: 60 }),
  };
}
```

OpenTUI 的渲染循环每帧做三件事：

```js
async loop() {
  ...
  this.root.render(this.nextRenderBuffer, g);   // ① Solid 组件树 → 帧缓冲
  for (let x of this.postProcessFns) x(this.nextRenderBuffer, g);
  if (this._console.renderToBuffer(this.nextRenderBuffer), !this._isDestroyed) {
    if (this.renderNative(), ...) {             // ② Zig 原生重绘 + diff
      ...
      this.renderTimeout = this.clock.setTimeout(() => { this.loop() },
                          this.targetFrameTime);   // ③ 16.7ms 后再来一帧
    }
  }
}
```

### 4.4 Zig debug allocator 的放大

栈里反复出现：

```
heap.debug_allocator.DebugAllocator(.{ .safety = false, .thread_safe = true, ... }).alloc
heap.debug_allocator.DebugAllocator(...).free
heap.arena_allocator.ArenaAllocator.alloc
heap.PageAllocator.free
```

OpenTUI 的 Zig 侧用的是 `DebugAllocator`（而非 `page_allocator`），每帧的重绘/分配要走一层额外簿记，叠加在 60fps 上。

### 4.5 为什么不随任务量变化

整条链路上：
- 动画定时器 —— 与任务无关
- Solid 重渲染 —— 触发频率由定时器决定，与任务无关
- OpenTUI 60fps 循环 —— 常驻，与任务无关

**所以"没任务也烧 CPU"不是异常，是这条链路的必然表现。** 有任务时反而只是在这 22% 之上再叠加工作量。

---

## 5. 修复与规避

### 5.1 已应用的修复

`~/.local/state/mimocode/kv.json`（TUI 的 KV 持久化存储）：

```diff
- "animations_enabled": true,
+ "animations_enabled": false,
```

- 原文件备份：`~/.local/state/mimocode/kv.json.bak-20261023-163039`
- 实测：21.8% → **0.7% – 1.1%**
- **只对新启动的实例生效**

### 5.2 界面内随时切换

TUI 内执行：

```
/app.toggle.animations
```

它会写回同一个 kv.json（`app.toggle.animations` 命令的 `onSelect` 直接调 `K.set("animations_enabled", ...)`）。

### 5.3 其他可用开关

| 方式 | 效果 |
|---|---|
| `MIMOCODE_TUI_PLAIN=1` | 纯文本 UI，2.3% |
| `MIMOCODE_DISABLE_MOUSE=1` | 关闭鼠标跟踪（`useMouse`/`enableMouseMovement`） |
| `visual_mode: "minimal"` | `YI0(mode, enabled) => mode==="vivid" && enabled`，非 vivid 模式同样不启用 motion |

### 5.4 给上游的三条建议（存档，暂未提交）

1. **空闲时暂停动画定时器**，或在没有活动时降到 30fps；只在有交互/任务时启动
2. **把 `targetFps` 做成可配置项**（如 `MIMOCODE_TUI_FPS`），而不是在 `OB2()` 里写死 60
3. **`animations_enabled` 默认值跟随终端能力 / 系统 `prefers-reduced-motion`**

---

## 6. 可复用工具箱

### 6.1 精确定位进程

```bash
lsof 2>/dev/null | grep -i mimo | awk '{print $1,$2,$9}' | sort -u
```

### 6.2 测量真实 CPU 占用

```bash
P=<pid>
t1=$(ps -p $P -o time= | tr -d ' '); sleep 10
t2=$(ps -p $P -o time= | tr -d ' ')
python3 -c "
def sec(t):
    p=[float(x) for x in '$t1'.split(':')]
    return p[-1]+60*p[-2]
a,b=sec('$t1'),sec('$t2'); print(f'{(b-a)/10*100:.1f}% of one core')"
```

### 6.3 无 TTY 环境下的可重复测量（pty）

普通 `&` 后台跑 TUI 会拿不到 pty，行为可能不同。用 Python 起一个 pty：

```python
import os, pty, subprocess, time, threading, signal
mfd, sfd = pty.openpty(); os.environ['TERM'] = 'xterm-256color'
p = subprocess.Popen(['/path/to/tui'], stdin=sfd, stdout=sfd, stderr=sfd,
                     cwd='/path/to/project', env=os.environ, preexec_fn=os.setsid)
os.close(sfd)
threading.Thread(target=lambda: [os.read(mfd, 65536) for _ in iter(int, 1)], daemon=True).start()

def cpu(pid):
    o = subprocess.run(['ps','-p',str(pid),'-o','time='], capture_output=True, text=True).stdout.strip()
    pp = [float(x) for x in o.split(':')]
    return pp[-1] + 60*pp[-2]

time.sleep(20)                 # 预热，避开启动高峰
c1 = cpu(p.pid); time.sleep(12); c2 = cpu(p.pid)
print(f"{(c2-c1)/12*100:.1f}% of one core")
os.killpg(os.getpgid(p.pid), signal.SIGKILL)
```

### 6.4 栈采样 + 叶子帧归因

```bash
sample $P 8 -f /tmp/s.txt
sed -n '/^Sort by top of stack/,/^$/p' /tmp/s.txt | head -20
```

### 6.5 从 Bun 单文件程序里挖源码

```bash
strings -a ~/.mimocode/bin/mimo > /tmp/mimo_strings.txt
grep -o -E ".{140}setInterval\(.{140}" /tmp/mimo_strings.txt
```

---

## 7. 踩坑清单

这几条都是本次实际浪费过时间的，值得单独记下来。

| # | 坑 | 说明 |
|---|---|---|
| 1 | **`ps %CPU` 不能当瞬时值** | 它是衰减的生命周期均值，会把启动高峰混进来。必须用 `time=` 字段做差值。 |
| 2 | **`sample` 的 "Total number in stack" 会重复计数** | 同一采样在树的每一层都被计入。统计必须自己解析、只取叶子帧。 |
| 3 | **解析 `sample` 时漏掉 `???` 帧** | stripped 的 Bun 二进制里全是 `???`，正则如果不显式接受 `???` 就会把**真正的热帧**全部丢掉，得出"几乎不忙"的错误结论。 |
| 4 | **`???` 帧要按地址偏移统计** | `atos` 对该二进制无符号，只能用 `load address + offset` 聚合，靠出现频次定位热点。 |
| 5 | **`OTUI_SHOW_STATS=1` 会污染输出速率测量** | 调试 overlay 每帧内容都变，会强制触发重绘，把 1 KB/s 的真实值放大到 56 KB/s。 |
| 6 | **macOS 没有 `timeout` 命令** | 需要 `gtimeout`（coreutils）或改用 `perl -e 'alarm...'` / Python。 |
| 7 | **`script -q` 的输出测速不准** | 有 4KB 缓冲，测出来是块状跳变。测字节率要用 pty 实时读。 |
| 8 | **进程会中途重启/退出** | 分析期间 mimo 被重启过多次（PID 10476 → 11896 → 12058）。每个结论都要在当时复核进程身份。 |
| 9 | **`proc_pid_rusage` 结构体布局要严格对齐** | 写错会返回全 0 或段错误，拿不到 user/system 拆分。 |
| 10 | **别在带调试 overlay 的实例上测任何东西** | 连 CPU 都会被 overlay 本身抬高。 |

---

## 8. 上游仓库现状（存档参考）

> 本次**未**向官方提交反馈（判断为不会被处理），以下仅作事实存档，供日后需要时复用。

- 仓库：`XiaomiMiMo/MiMo-Code`（public，MIT，13.7k stars）
- **Discussions** 分类：`Announcements` / `General` / `Ideas` / `Polls` / `Q&A` / `Show and tell`
- **Issues** 模板：`bug-report.yml` / `feature-request.yml` / `question.yml`
- 提交信息遵循 conventional commits（如 `fix(tui): ...`、`feat(session): ...`）
- 检索结果：**没有**与本问题重复的 issue/discussion

相关但**不同根因**的已有 issue：

| Issue | 标题 | 状态 | 与本问题的关系 |
|---|---|---|---|
| #1596 | 打开 mimocode 后点击初始页面空白区导致 CPU 占用率高 | closed | **最接近**。但官方回复归因于终端不支持转义序列（建议换 Windows Terminal），未触及动画定时器根因 |
| #2171 | 0.1.13 严重 bug，CPU 占用超载 | closed | 未给出根因即关闭（#2582 推测其与 Bun GC 相关） |
| #2582 | Headless `mimo run` 流式输出时占用 ~45% 核 | open | 归因于 Bun 1.3.14 的 GC 节奏，与**本问题（无头 0.4%）不同源** |
| #728 | 建议补充 performance issue 模板 | open | 反映社区对性能类反馈的需求 |

**结论**：本问题（**TUI 空闲**状态下由动画定时器驱动的持续 CPU 占用）在上游尚无对应条目；若日后要提，应走 **Issue + `bug-report.yml`**（而非 Discussions），标题建议 `fix(tui): ...`，并附上本文件 §3.4 的对照实验矩阵作为证据。

---

*文档生成时间：2026-10-23 16:40*
