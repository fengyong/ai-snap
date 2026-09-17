import Cocoa

//  探针 10 — 水印文本框的提交时机（报告 P2-1）
//
//  在真实 AnnotationWindow 上做行为验证：
//  把水印框改掉 → 让焦点离开（模拟"直接去点保存"）→ 看 watermarkConfig.text 是否更新。

@main
struct WatermarkProbe {
    static var window: AnnotationWindow?

    static func main() {
        bootstrapApp(policy: .regular)
        NSApp.activate(ignoringOtherApps: true)
        let w = AnnotationWindow(image: blankCanvas(600, 400))
        window = w
        w.makeKeyAndOrderFront(nil)
        RunLoop.main.add(Timer(timeInterval: 0.4, repeats: false) { _ in inspect() }, forMode: .common)
        NSApp.run()
    }

    static func inspect() {
        guard let w = window, let content = w.contentView else { return }

        func findCanvas(_ v: NSView) -> AnnotationView? {
            if let a = v as? AnnotationView { return a }
            for s in v.subviews { if let f = findCanvas(s) { return f } }
            return nil
        }
        guard let canvas = content.subviews.compactMap({ findCanvas($0) }).first else {
            Probe.note("P2-1", "未找到画布，跳过"); Probe.finish("probe_watermark")
        }
        // 水印输入框：工具栏里 stringValue 为默认值 "AISnap" 的可编辑文本框
        let fields = content.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSTextField }
        guard let field = fields.first(where: { $0.isEditable && $0.stringValue == "AISnap" }) else {
            Probe.note("P2-1", "未找到水印输入框，跳过"); Probe.finish("probe_watermark")
        }

        Probe.section("P2-1 水印文本的提交时机")
        let cell = field.cell as? NSTextFieldCell
        Probe.note("P2-1", "NSTextFieldCell.sendsActionOnEndEditing = \(cell?.sendsActionOnEndEditing ?? false)（false = 只有回车/Tab 才发送 action）")

        let before = canvas.watermarkConfig.text
        w.makeFirstResponder(field)
        field.stringValue = "自定义水印"
        // 模拟用户输入完直接去点别处（焦点离开输入框）
        w.makeFirstResponder(canvas)
        let afterBlur = canvas.watermarkConfig.text
        Probe.note("P2-1", "输入框显示 \"\(field.stringValue)\"，焦点离开后 watermarkConfig.text = \"\(afterBlur)\"（原值 \"\(before)\"）")

        if afterBlur == field.stringValue {
            Probe.ok("P2-1", "焦点离开时水印文本已同步", "text = \(afterBlur)")
        } else {
            Probe.bug("P2-1", "输入水印后只要不按回车，导出用的仍是旧文本（action 只在回车/Tab 触发）",
                      "输入框 = \"\(field.stringValue)\"，实际生效 = \"\(afterBlur)\"",
                      expect: "应实时同步（controlTextDidChange）或至少 sendsActionOnEndEditing = true")
        }

        // 反证：手动触发 action 时确实会同步 → 说明接线本身没错，只是触发时机不对
        field.sendAction(field.action, to: field.target)
        let afterAction = canvas.watermarkConfig.text
        if afterAction == field.stringValue {
            Probe.note("P2-1", "手动触发 action 后同步成功（text = \"\(afterAction)\"）→ 证明只是触发时机问题")
        } else {
            Probe.note("P2-1", "手动触发 action 后仍未同步（text = \"\(afterAction)\"）→ 接线本身可能有问题")
        }

        Probe.finish("probe_watermark")
    }
}
