import Cocoa

//  探针 05 — 聚光灯叠加（报告 P1-4）
//
//  两个重叠的聚光灯：正确行为是"重叠区依然明亮"，
//  当前实现因 ctx.clip(using: .evenOdd) 使重叠区重新变暗。

@main
struct SpotlightProbe {
    static func main() {
        bootstrapApp()
        Probe.section("P1-4 两个聚光灯重叠处的亮度")

        let v = newCanvas(500, 400)
        v.currentTool = .spotlight
        drag(v, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))
        drag(v, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        let image = v.compositeImage()

        let outside = luminance(image, at: CGPoint(x: 400, y: 60))     // 未被任何聚光灯覆盖
        let single  = luminance(image, at: CGPoint(x: 75, y: 125))     // 仅被第一个覆盖
        let overlap = luminance(image, at: CGPoint(x: 125, y: 125))    // 两个的交集
        Probe.note("P1-4", String(format: "亮度：聚光灯外 %.3f，单个聚光灯内 %.3f，重叠区 %.3f",
                                  outside, single, overlap))

        if single - outside < 0.2 {
            Probe.bug("P1-4a", "单个聚光灯没有产生提亮效果，探针前置条件不满足",
                      String(format: "内 %.3f vs 外 %.3f", single, outside),
                      expect: "内部应明显亮于外部")
        } else {
            Probe.ok("P1-4a", "单个聚光灯能提亮选区",
                     String(format: "内 %.3f vs 外 %.3f", single, outside))
        }

        // 重叠区应当和单个聚光灯区域同样明亮（差值仅来自多叠加的一层白色高光）
        if overlap > single - 0.05 {
            Probe.ok("P1-4b", "重叠的聚光灯不会重新压暗交集",
                     String(format: "重叠 %.3f vs 单个 %.3f", overlap, single))
        } else {
            Probe.bug("P1-4b", "重叠的聚光灯把交集重新压暗（.evenOdd 裁剪把交集算成需要遮罩）",
                      String(format: "重叠区 %.3f 明显暗于单个聚光灯区 %.3f 与外部 %.3f",
                             overlap, single, outside),
                      expect: "重叠区应 ≥ 单个聚光灯区亮度（README 宣称支持多聚光灯叠加）")
        }

        Probe.finish("probe_spotlight")
    }
}
