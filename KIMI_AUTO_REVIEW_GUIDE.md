# 🤖 Kimi Code Review 自动化提交指南

**作者:** [Kimi](https://kimi.moonshot.cn) · 月之暗面（Moonshot AI）  
**创建日期:** 2026-03-28  
**适用项目:** AISnap - macOS 截图标注工具

---

## 📋 目录

1. [方案概述](#方案概述)
2. [方案1: GitHub Actions 自动触发](#方案1-github-actions-自动触发-推荐)
3. [方案2: PowerShell 脚本](#方案2-powershell-脚本)
4. [方案3: 批处理脚本](#方案3-批处理脚本)
5. [方案4: 单条命令](#方案4-单条命令)
6. [快速开始](#快速开始)
7. [常见问题](#常见问题)

---

## 方案概述

本指南提供 **4 种方式** 自动将 Kimi Code Review 意见提交到 GitHub PR：

| 方案 | 自动化程度 | 适用场景 | 技术门槛 |
|------|:----------:|----------|:--------:|
| **方案1** | ⭐⭐⭐⭐⭐ 全自动 | 长期项目，持续集成 | 低 |
| **方案2** | ⭐⭐⭐⭐ 半自动 | 本地开发，灵活控制 | 中 |
| **方案3** | ⭐⭐⭐ 手动触发 | 偶尔使用，简单快速 | 低 |
| **方案4** | ⭐⭐ 单次执行 | 临时使用，测试验证 | 高 |

---

## 方案1: GitHub Actions 自动触发（推荐⭐）

### 功能特点

- ✅ **完全自动化**: 新 PR 创建/更新时自动触发 Review
- ✅ **无需本地环境**: 在 GitHub 云端执行
- ✅ **自动署名**: 每条 Review 都标注 "Reviewed by Kimi"
- ✅ **支持手动触发**: 可选择特定 PR 进行 Review

### 文件位置

```
.github/workflows/kimi-code-review.yml
```

### 工作原理

```
开发者提交 PR
      ↓
GitHub Actions 自动检测
      ↓
执行 Kimi Code Review 工作流
      ↓
自动提交 Review 评论到 PR
```

### 使用步骤

#### 步骤1: 部署工作流

确保 `.github/workflows/kimi-code-review.yml` 文件已合并到主分支。

```bash
# 如果尚未合并，合并 PR #2
git checkout master
git merge kimi-review-fixes
git push origin master
```

#### 步骤2: 验证工作流

1. 访问: https://github.com/fengyong/ai-snap/actions
2. 应该能看到 "Kimi Code Review" 工作流

#### 步骤3: 测试自动触发

创建一个新 PR，观察是否自动收到 Kimi Review：

```bash
# 创建测试分支
git checkout -b test-auto-review
echo "# Test" >> README.md
git add . && git commit -m "test: 验证自动 Review"
git push origin test-auto-review

# 创建 PR（命令行或网页）
gh pr create --title "Test: 自动 Review" --body "测试 GitHub Actions"
```

#### 步骤4: 手动触发（可选）

1. 进入 Actions 页面
2. 选择 "Kimi Code Review" 工作流
3. 点击 "Run workflow"
4. 输入 PR 编号
5. 点击 "Run workflow"

---

## 方案2: PowerShell 脚本

### 功能特点

- ✅ **功能最全**: 支持自动检测 PR、多种 Review 类型
- ✅ **彩色输出**: 友好的命令行界面
- ✅ **灵活配置**: 可指定 PR 编号、仓库、Review 类型
- ✅ **错误处理**: 完善的错误提示和验证

### 文件位置

```
kimi-auto-review.ps1
```

### 前置要求

```powershell
# 1. 安装 GitHub CLI
winget install --id GitHub.cli

# 2. 登录 GitHub
& 'C:\Program Files\GitHub CLI\gh.exe' auth login --web
```

### 使用方式

#### 方式A: 自动检测最新 PR

```powershell
# 进入项目目录
cd d:\ai-coding\qoder\ai-snap

# 运行脚本（自动检测最新 PR）
.\kimi-auto-review.ps1
```

**交互流程:**
```
🤖 Kimi Code CLI - 自动化 PR Review

[1/3] 检查环境...
[✅] 环境检查通过

[2/3] 获取开放的 PR 列表...
找到 PR #3: 修复 Kimi Review 的 Bug
是否对该 PR 提交 Review? (Y/n): Y

[3/3] 正在提交 Review...
✅ Kimi Review 提交成功！
🔗 查看: https://github.com/fengyong/ai-snap/pull/3
```

#### 方式B: 指定 PR 编号

```powershell
# 对特定 PR 提交 Review
.\kimi-auto-review.ps1 -PRNumber 3
```

#### 方式C: 指定 Review 类型

```powershell
# 提交 "Comment" 类型（默认）
.\kimi-auto-review.ps1 -PRNumber 3 -ReviewType COMMENT

# 提交 "Request Changes" 类型（阻止合并）
.\kimi-auto-review.ps1 -PRNumber 3 -ReviewType REQUEST_CHANGES

# 提交 "Approve" 类型（批准合并）
.\kimi-auto-review.ps1 -PRNumber 3 -ReviewType APPROVE
```

#### 方式D: 指定其他仓库

```powershell
# 对其他仓库提交 Review
.\kimi-auto-review.ps1 -PRNumber 5 -Repo "other-user/other-repo"
```

### 参数说明

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|:----:|:----:|--------|------|
| `PRNumber` | int | 否 | 0 | PR 编号，0 表示自动检测 |
| `Repo` | string | 否 | fengyong/ai-snap | 目标仓库 |
| `ReviewType` | enum | 否 | COMMENT | COMMENT / REQUEST_CHANGES / APPROVE |

---

## 方案3: 批处理脚本

### 功能特点

- ✅ **最简单**: 双击即可运行
- ✅ **无依赖**: 不需要 PowerShell 知识
- ✅ **交互式**: 引导式操作

### 文件位置

```
kimi-auto-review.bat
```

### 使用方式

#### 双击运行

1. 打开文件资源管理器
2. 进入项目目录 `d:\ai-coding\qoder\ai-snap`
3. **双击** `kimi-auto-review.bat`
4. 按提示输入 PR 编号
5. 完成

#### 命令行运行

```cmd
cd d:\ai-coding\qoder\ai-snap
kimi-auto-review.bat
```

### 运行流程

```
🤖 Kimi Code CLI - 自动化 PR Review

[1/3] 检查 GitHub CLI...
[2/3] 检查 GitHub 认证...
[✅] 认证通过

[3/3] 获取开放的 PR 列表...
#3  feat: 新功能
#2  docs: Kimi Code Review

请输入要 Review 的 PR 编号: 3

📝 正在生成 Kimi Review 报告...
📤 正在提交 Review...

[✅] Kimi Review 提交成功！
🔗 查看: https://github.com/fengyong/ai-snap/pull/3

按任意键继续...
```

---

## 方案4: 单条命令

### 功能特点

- ✅ **最快速**: 无需脚本文件
- ✅ **一次执行**: 适合临时使用
- ✅ **可复制**: 直接粘贴到终端

### 使用方式

#### 基础命令

```powershell
# 设置变量
$PR_NUMBER = 3
$REPO = "fengyong/ai-snap"

# 生成 Review 内容并提交
$body = @'
## 📝 Code Review by Kimi

### 🔴 Bug 1: Undo/Redo 逻辑错误
详见 Issue #1

### 🔴 Bug 2: 多显示器支持不完整
...

*🤖 Reviewed by Kimi · 月之暗面*
'@

# 创建临时文件并提交
$t = [System.IO.Path]::GetTempFileName()
$body | Out-File $t -Encoding UTF8
& 'C:\Program Files\GitHub CLI\gh.exe' pr review $PR_NUMBER --repo $REPO --comment --body-file $t
Remove-Item $t
```

#### 简化版命令

```powershell
# 极简版（适合快速测试）
$t=[IO.Path]::GetTempFileName(); "Kimi Review 测试" | Out-File $t; & 'C:\Program Files\GitHub CLI\gh.exe' pr review 2 --repo fengyong/ai-snap --comment --body-file $t; del $t
```

---

## 快速开始

### 首次使用 checklist

- [ ] 1. 安装 GitHub CLI
  ```powershell
  winget install --id GitHub.cli
  ```

- [ ] 2. 登录 GitHub
  ```powershell
  & 'C:\Program Files\GitHub CLI\gh.exe' auth login --web
  ```

- [ ] 3. 验证登录
  ```powershell
  & 'C:\Program Files\GitHub CLI\gh.exe' auth status
  ```

- [ ] 4. 选择方案并执行
  - 推荐方案1: 合并工作流，之后全自动
  - 推荐方案2: 运行 `kimi-auto-review.ps1`

### 日常使用

```powershell
# 方案1: 无需操作，自动触发
# 方案2: 运行脚本
.\kimi-auto-review.ps1

# 方案3: 双击 kimi-auto-review.bat
# 方案4: 复制粘贴命令
```

---

## 常见问题

### Q1: 提示 "GitHub CLI 未安装"

**解决:**
```powershell
winget install --id GitHub.cli
# 重启终端
```

### Q2: 提示 "GitHub 未认证"

**解决:**
```powershell
& 'C:\Program Files\GitHub CLI\gh.exe' auth login --web
# 按提示在浏览器完成授权
```

### Q3: 提示 "没有找到开放的 PR"

**原因:** 当前仓库没有 open 状态的 PR

**解决:**
```powershell
# 查看所有 PR（包括 closed）
gh pr list --state all

# 或创建新 PR
git checkout -b new-feature
git push origin new-feature
gh pr create --title "新功能" --body "描述"
```

### Q4: 提示 "Review 提交失败"

**可能原因:**
1. 对自己的 PR 提交 `REQUEST_CHANGES`（GitHub 不允许）
2. PR 已被合并或关闭
3. 网络问题

**解决:**
```powershell
# 检查 PR 状态
gh pr view <PR_NUMBER> --repo fengyong/ai-snap

# 使用 COMMENT 类型代替 REQUEST_CHANGES
.\kimi-auto-review.ps1 -PRNumber 3 -ReviewType COMMENT
```

### Q5: 如何修改 Review 内容？

**方案1:** 编辑工作流文件  
`.github/workflows/kimi-code-review.yml`

**方案2/3:** 编辑脚本文件  
`kimi-auto-review.ps1` 或 `kimi-auto-review.bat`

**方案4:** 直接修改命令中的 `$body` 变量

---

## 附录: Review 内容模板

如需自定义 Review 内容，使用以下模板：

```markdown
## 📝 Code Review 报告

**Reviewed by [Kimi](https://kimi.moonshot.cn) · 月之暗面（Moonshot AI）**

> 本报告由 Kimi Code CLI 自动生成

### 🔴 Bug 1: [标题]
**文件**: `文件路径` (行号)

问题描述...

### 🔴 Bug 2: [标题]
...

## 📊 总体评分

| 维度 | 评分 | 评价 |
|------|:----:|------|
| 架构设计 | ⭐⭐⭐⭐⭐ | 评价... |
| 代码质量 | ⭐⭐⭐⭐ | 评价... |
| 可维护性 | ⭐⭐⭐⭐ | 评价... |
| 功能完整性 | ⭐⭐⭐⭐ | 评价... |

*🤖 Generated by Kimi Code CLI | [月之暗面](https://www.moonshot.cn)*
```

---

## 相关链接

- 🏠 **项目仓库:** https://github.com/fengyong/ai-snap
- 🤖 **Kimi 官网:** https://kimi.moonshot.cn
- 📋 **Issue #1 (Bug 清单):** https://github.com/fengyong/ai-snap/issues/1
- 🔀 **PR #2 (Review 示例):** https://github.com/fengyong/ai-snap/pull/2
- 📖 **GitHub CLI 文档:** https://cli.github.com/manual

---

**本文档由 Kimi Code CLI 自动生成**  
*最后更新: 2026-03-28*
