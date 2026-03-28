# 贡献指南 Contributing Guide

感谢您对 AISnap 的兴趣！我们欢迎所有形式的贡献。

## 🤝 如何贡献

### 1. 提交 Pull Request

1. **Fork 本仓库** 到您的 GitHub 账号
2. **克隆您的 Fork** 到本地
   ```bash
   git clone https://github.com/YOUR_USERNAME/ai-snap.git
   ```
3. **创建新分支**
   ```bash
   git checkout -b feature/your-feature-name
   # 或
   git checkout -b fix/issue-description
   ```
4. **提交修改**
   ```bash
   git add .
   git commit -m "type: 描述"
   ```
5. **推送到您的 Fork**
   ```bash
   git push origin feature/your-feature-name
   ```
6. **创建 Pull Request** 到 `fengyong/ai-snap`

### 2. 提交 Issue

发现 Bug 或有新功能建议？欢迎提交 Issue：
- [Bug 报告](https://github.com/fengyong/ai-snap/issues/new?labels=bug)
- [功能建议](https://github.com/fengyong/ai-snap/issues/new?labels=enhancement)

### 3. Code Review

我们使用 [Kimi Code CLI](https://kimi.moonshot.cn) 进行自动化代码审查。
提交 PR 后将自动触发 AI Review。

## 📝 提交规范

### Commit Message 格式
```
<type>: <subject>

<body>
```

**Type 类型：**
- `feat`: 新功能
- `fix`: Bug 修复
- `docs`: 文档更新
- `style`: 代码格式调整
- `refactor`: 重构
- `test`: 测试相关
- `chore`: 构建/工具相关

**示例：**
```
fix: 修复 Undo/Redo 逻辑错误

docs: 更新 README 截图

feat: 添加箭头样式切换 UI
```

## 🐛 当前待修复问题

详见 [Issue #1](https://github.com/fengyong/ai-snap/issues/1) 的 Kimi Code Review 报告：

- [ ] 🔴 Undo/Redo 逻辑错误
- [ ] 🔴 多显示器支持不完整
- [ ] 🟡 箭头样式按钮未绑定功能
- [ ] 🟡 Hit Test 颜色 Key 溢出风险
- [ ] 🟡 SpotlightShape boundingBox 未考虑旋转
- [ ] 🟡 DrawingTool Equatable 实现问题

## 💡 开发建议

### 环境要求
- macOS 13+
- Swift 5.9+
- Xcode 15+

### 构建运行
```bash
swift build -c release
.build/arm64-apple-macosx/release/AISnap
```

### 代码风格
- 遵循 [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- 使用 4 空格缩进
- 添加必要的注释

## 📞 联系方式

- Issue: [GitHub Issues](https://github.com/fengyong/ai-snap/issues)
- Email: [您的邮箱]

---

**感谢所有贡献者！** 🙏
