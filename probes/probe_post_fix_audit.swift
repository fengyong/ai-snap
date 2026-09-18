import Cocoa

//  针对「24 项修复之后」的当前实现做独立复核。
//
//  全部为黑盒验证：用真实 NSEvent 驱动 AnnotationView / 读导出图的真实像素 /
//  与暴力搜索的几何真值对比。不依赖任何源码内部字段。
//
//  编号用 NEW-x，避免与 CODE_REVIEW.md / CODE_REVIEW_ROUND1.md 的编号混淆。

@main
struct PostFixAudit {

    // MARK: - 工具

    /// 统计导出图里的"黄色像素"（聚光灯编辑器虚线的特征色）
    static func yellowStats(_ image: NSImage) -> (count: Int, sample: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return (-1, "no rep") }
        var count = 0
        var sample = "-"
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                if r > 0.5, g > 0.35, b < 0.35, (r - b) > 0.3 {
                    count += 1
                    if sample == "-" {
                        sample = String(format: "rgb(%.2f,%.2f,%.2f) @(%d,%d)", r, g, b, x, y)
                    }
                }
            }
        }
        return (count, sample)
    }

    /// 矩形 (300,100)-(500,300) + 一根"终点附着到矩形左边中点"的箭头。
    ///
    /// 箭头从 (150,200) 画到 (295,200)：终点距矩形左边 5pt，落在 12pt 吸附阈值内，
    /// 会被吸到 (300,200) 并附着成 snapPoint(index: 8)（左边中点）。
    /// 起点 (150,200) 远离矩形 —— 这一点很关键：矩形 Layer B 的命中带是 ±10.5pt
    /// （线宽 15 + 6 的一半），若起点落在带内，mouseDown 会命中矩形并变成"拖动矩形"。
    static func attachmentCanvas() -> AnnotationView {
        let v = newCanvas(1200, 400)
        v.currentTool = .rectangle
        drag(v, from: CGPoint(x: 300, y: 100), to: CGPoint(x: 500, y: 300))
        v.currentTool = .arrow
        drag(v, from: CGPoint(x: 150, y: 200), to: CGPoint(x: 295, y: 200))
        return v
    }

    /// 抓住矩形底边中点整体右移 300pt
    static func moveRectRight(_ v: AnnotationView) {
        drag(v, from: CGPoint(x: 400, y: 100), to: CGPoint(x: 700, y: 100))
    }

    /// 指针位置上是否有对象（黑盒：ESC 清空选中后点一下，看 selectedKey）
    static func hits(_ v: AnnotationView, _ p: CGPoint) -> Bool {
        selects(v, at: p)
    }

    // MARK: - 入口

    static func main() {
        bootstrapApp()

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-A  聚光灯的编辑器虚线边框是否被渲染进导出图")
        // ─────────────────────────────────────────────────────────────
        do {
            let clean = newCanvas(400, 300)
            let cleanStats = yellowStats(clean.compositeImage())

            let spot = newCanvas(400, 300)
            spot.currentTool = .spotlight
            drag(spot, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 220))
            let spotStats = yellowStats(spot.compositeImage())

            if spotStats.count > 0 {
                Probe.bug("NEW-A",
                          "Spotlight 的编辑器虚线边框被画进了导出图",
                          "含聚光灯的导出图有 \(spotStats.count) 个黄色像素（示例 \(spotStats.sample)）；"
                            + "同尺寸空画布为 \(cleanStats.count) 个",
                          expect: "导出图为 0 个黄色像素 —— 虚线边框是编辑器 UI，"
                            + "CODE_REVIEW_ROUND1.md 的 P0-2 要求导出时只保留遮罩、不描边")
            } else {
                Probe.ok("NEW-A", "Spotlight 边框未进导出图", "0 个黄色像素")
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-B  线宽滑块的撤销粒度：一次拖拽产生多少条 undo")
        // ─────────────────────────────────────────────────────────────
        do {
            let v = newCanvas(400, 300)
            v.currentTool = .rectangle
            drag(v, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
            _ = hits(v, CGPoint(x: 150, y: 100))
            let original = v.selectedObjectLineWidth ?? -1

            // 模拟一次"用户拖动线宽滑块"，走的是 AnnotationWindow 实际使用的通路：
            // 拖动中连续 preview（不记账）→ 松手时 commit 一次。
            // （旧实现是每次连续 action 都 append 一条 .restyle，所以这里以前直接调 restyleSelection）
            for w: CGFloat in [3, 5, 7, 9, 11, 13] {
                v.previewSelectionLineWidth(w)
            }
            v.commitSelectionLineWidth(from: original)
            let afterDrag = v.selectedObjectLineWidth ?? -1

            v.performUndo()                                   // 用户按一次 Cmd+Z
            _ = hits(v, CGPoint(x: 150, y: 100))
            let afterOneUndo = v.selectedObjectLineWidth ?? -1

            if afterOneUndo != original {
                Probe.bug("NEW-B",
                          "一次滑块拖拽被拆成多条 undo，Cmd+Z 无法一次撤销",
                          "原始线宽 \(original) → 拖到 \(afterDrag) → 按 1 次 Cmd+Z 后为 \(afterOneUndo)",
                          expect: "一次 Cmd+Z 应回到拖动前的 \(original)")
            } else {
                Probe.ok("NEW-B", "滑块拖拽可被一次撤销", "1 次 Cmd+Z 回到 \(original)")
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-C  亚像素拖拽是否静默摧毁箭头附着、且不留撤销记录")
        // ─────────────────────────────────────────────────────────────
        do {
            // C0 对照组：完全不拖，只移动父矩形 → 箭头端点应跟随到 (600,200)，
            //    于是箭头覆盖 x∈[150,600]，探针 (500,200) 命中。
            let c0 = attachmentCanvas()
            moveRectRight(c0)
            if hits(c0, CGPoint(x: 500, y: 200)) {
                Probe.ok("NEW-C0", "附着的箭头会跟随父矩形移动", "移动后 (500,200) 命中箭头")
            } else {
                Probe.bug("NEW-C0", "附着的箭头不跟随父矩形",
                          "移动后 (500,200) 无命中", expect: "端点应跟到 (600,200)")
            }

            // C1 对照：拖 1.0pt（> 0.5 阈值）→ 应入栈；撤销后箭头仍在
            let c1 = attachmentCanvas()
            drag(c1, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 201, y: 200))
            c1.performUndo()
            if hits(c1, CGPoint(x: 200, y: 200)) {
                Probe.ok("NEW-C1", "拖动 1.0pt 会记录 undo，撤销后箭头仍在", "箭头存在")
            } else {
                Probe.bug("NEW-C1", "拖动 1.0pt 也未记录 undo",
                          "撤销后箭头消失（撤销的是 .add）", expect: "撤销的应是 .move，箭头仍在")
            }

            // C2 主实验：拖 0.5pt（= 2x 屏上 1 物理像素）之后必须**没有任何副作用**。
            //
            // 这里不能用"按一次 Cmd+Z 看箭头还在不在"来判定 —— 修复后的正确行为是
            // 这次拖拽被当成无操作（位置回退、附着保留），于是撤销栈顶仍是更早的 .add，
            // 撤销后箭头照样消失。旧实现与修复实现在那个断言上表现相同，
            // 真正能区分两者的是"附着有没有被摧毁"，所以下面直接测附着。
            let c2 = attachmentCanvas()
            drag(c2, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200.5, y: 200))
            moveRectRight(c2)
            if hits(c2, CGPoint(x: 500, y: 200)) {
                Probe.ok("NEW-C2", "0.5pt 拖拽不解除附着（被当作无操作）",
                         "移动父矩形后箭头仍跟随到 (500,200)")
            } else {
                Probe.bug("NEW-C2",
                          "0.5pt 拖拽已解除附着却没有任何撤销记录 → 关系不可恢复",
                          "移动父矩形后 (500,200) 无命中：箭头端点停在原处，附着已被清空",
                          expect: "与 C0 一致，箭头应跟随；或至少能被 Cmd+Z 还原")
            }

            // C3：亚像素拖拽不应留下"半应用"的记录
            let c3 = attachmentCanvas()
            drag(c3, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200.5, y: 200))
            c3.performUndo()
            if !hits(c3, CGPoint(x: 200, y: 200)) {
                Probe.ok("NEW-C3", "0.5pt 拖拽不产生撤销记录（无记录 ⇔ 无变化）",
                         "撤销栈顶仍是更早的 .add")
            } else {
                Probe.ok("NEW-C3", "0.5pt 拖拽留下了记录",
                         "撤销掉的是一次 .move，箭头仍在")
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-D  椭圆 nearestPerimeterPoint：径向投影 vs 几何真值")
        // ─────────────────────────────────────────────────────────────
        do {
            let cases: [(CGFloat, CGFloat, CGPoint)] = [
                (200, 10, CGPoint(x: 100, y: 50)),
                (300, 40, CGPoint(x: 250, y: 10)),
                (200, 200, CGPoint(x: 90, y: 60)),
            ]
            var worstExcess: CGFloat = 0
            var worstDesc = ""
            var lines: [String] = []
            for (rx, ry, q) in cases {
                let e = CircleShape(center: .zero, radiusX: rx, radiusY: ry,
                                    color: .red, lineWidth: 2, hitTestColorKey: 1)
                let got = e.nearestPerimeterPoint(to: q)
                var bestD = CGFloat.greatestFiniteMagnitude
                let steps = 400_000
                for i in 0..<steps {
                    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                    let p = CGPoint(x: rx * cos(t), y: ry * sin(t))
                    let d = hypot(p.x - q.x, p.y - q.y)
                    if d < bestD { bestD = d }
                }
                let gotD = hypot(got.x - q.x, got.y - q.y)
                let excess = gotD - bestD
                lines.append(String(format: "rx=%.0f ry=%.0f: 返回点距查询点 %.1f，真值 %.1f，超出 %.1f pt",
                                    rx, ry, gotD, bestD, excess))
                if excess > worstExcess {
                    worstExcess = excess
                    worstDesc = String(format: "rx=%.0f ry=%.0f q=(%.0f,%.0f)", rx, ry, q.x, q.y)
                }
            }
            for l in lines { Probe.note("NEW-D", l) }
            if worstExcess > 1 {
                Probe.bug("NEW-D",
                          "偏心椭圆的 nearestPerimeterPoint 只是径向投影，不是最近点",
                          String(format: "最差用例 %@，比几何真值远 %.1f pt", worstDesc, worstExcess),
                          expect: "返回值距查询点的距离应等于真值（偏差 < 1pt）")
            } else {
                Probe.ok("NEW-D", "椭圆最近点误差可忽略",
                         String(format: "最大超出 %.3f pt", worstExcess))
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-E  贴纸工具在工具栏重建（点「换色」）后的高亮与下拉框状态")
        // ─────────────────────────────────────────────────────────────
        do {
            let win = AnnotationWindow(image: blankCanvas(400, 300))
            if let root = win.contentView, let canvas = findCanvas(root) {
                canvas.currentTool = .stamp(.checkmark)

                // 触发一次工具栏重建 —— 这正是用户点「换色」时发生的事
                if let paletteBtn = findButton(titled: "换色", in: root) {
                    paletteBtn.performClick(nil)
                } else {
                    Probe.note("NEW-E", "找不到「换色」按钮")
                }

                let toolTitles: Set<String> = ["箭头", "矩形", "圆形", "椭圆", "聚光"]
                let lit = buttons(in: root)
                    .filter { toolTitles.contains($0.title) && $0.state == .on }
                    .map { $0.title }
                let popupIndex = popUps(in: root).first?.indexOfSelectedItem ?? -1
                let expectedIndex = 1     // defaultStamps[0] = ✓，下拉框第 0 项是占位的「选择」

                if lit.isEmpty && popupIndex == expectedIndex {
                    Probe.ok("NEW-E", "工具栏重建后贴纸状态正确",
                             "无绘图按钮被点亮；贴纸下拉框停在第 \(popupIndex) 项（✓）")
                } else {
                    Probe.bug("NEW-E",
                              "工具栏重建后贴纸工具状态错乱",
                              "被点亮的绘图按钮 = \(lit.isEmpty ? "无" : lit.joined(separator: "/"))；"
                                + "贴纸下拉框选中项 = \(popupIndex)",
                              expect: "不应点亮任何绘图按钮（旧实现回退到 0 → 点亮「箭头」），"
                                + "且下拉框应停在 \(expectedIndex)（✓）")
                }
            } else {
                Probe.note("NEW-E", "拿不到 AnnotationWindow 的画布，跳过")
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-F  1x1 图像被判定为「全透明」→ 权限兜底探测在 1x 屏失效")
        // ─────────────────────────────────────────────────────────────
        do {
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            let opaque1x1 = ctx.makeImage()!

            if ScreenCapture.isFullyTransparent(opaque1x1) {
                Probe.bug("NEW-F",
                          "不透明的 1x1 图像被 isFullyTransparent 判为「全透明」",
                          "1x1 不透明白图 → isFullyTransparent = true（guard w>1,h>1 直接 return true）",
                          expect: "应返回 false；否则 AppDelegate.hasScreenCapturePermission 的兜底探测"
                            + "在 1x 屏上恒为「无权限」")
            } else {
                Probe.ok("NEW-F", "1x1 不透明图判定正确", "false")
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-G  hasEdits 的语义：画布已空仍报「有未导出标注」")
        // ─────────────────────────────────────────────────────────────
        do {
            let v = newCanvas(400, 300)
            v.currentTool = .rectangle
            drag(v, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
            let afterDraw = v.hasEdits

            _ = hits(v, CGPoint(x: 150, y: 100))
            pressDelete(v)                                  // 删掉刚画的矩形
            let afterDelete = v.hasEdits

            if afterDraw && afterDelete {
                Probe.bug("NEW-G",
                          "标注已全部删除、画布与原图完全一致，仍被判定为「有未导出的标注」",
                          "画完 hasEdits=\(afterDraw)；全部删除后 hasEdits=\(afterDelete)"
                            + "（实现是 !undoStack.isEmpty，只看栈不看画布结果）",
                          expect: "画布回到初始状态时应为 false，"
                            + "否则关闭窗口/重新截图会弹无谓的「放弃当前标注？」确认框")
            } else {
                Probe.ok("NEW-G", "hasEdits 语义正确",
                         "afterDraw=\(afterDraw) afterDelete=\(afterDelete)")
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-H  画聚光灯的过程中，已有聚光灯的压暗是否被叠加了两次")
        // ─────────────────────────────────────────────────────────────
        do {
            let S1a = CGPoint(x: 50, y: 50), S1b = CGPoint(x: 150, y: 150)
            let S2a = CGPoint(x: 250, y: 150), S2b = CGPoint(x: 400, y: 300)
            let outside = CGPoint(x: 460, y: 350)   // 两个聚光灯之外

            // 基准：两个聚光灯都画完
            let done = newCanvas(500, 400)
            done.currentTool = .spotlight
            drag(done, from: S1a, to: S1b)
            drag(done, from: S2a, to: S2b)
            let finalL = renderLuminance(done, at: outside)

            // 预览：S1 已存在，S2 拖到一半（不松手）
            let mid = newCanvas(500, 400)
            mid.currentTool = .spotlight
            drag(mid, from: S1a, to: S1b)
            mid.mouseDown(with: mouseEvent(.leftMouseDown, S2a))
            mid.mouseDragged(with: mouseEvent(.leftMouseDragged, S2b))
            let previewL = renderLuminance(mid, at: outside)
            mid.mouseUp(with: mouseEvent(.leftMouseUp, S2b))

            if abs(previewL - finalL) > 0.05 {
                Probe.bug("NEW-H",
                          "拖拽聚光灯时的预览把已有聚光灯的遮罩又叠了一遍（画布比成品黑得多）",
                          String(format: "两灯之外同一点亮度：拖拽预览中 %.3f，松手后成品 %.3f", previewL, finalL),
                          expect: "预览应与成品一致（差值 < 0.05）—— "
                            + "drawSpotlightOverlay 与 drawPreview 各铺一次 0.55 黑")
            } else {
                Probe.ok("NEW-H", "聚光灯预览与成品亮度一致",
                         String(format: "预览 %.3f vs 成品 %.3f", previewL, finalL))
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-I  程序化关窗（为了开新截图）后 activationPolicy 是否残留为 .regular")
        // ─────────────────────────────────────────────────────────────
        do {
            let w1 = AnnotationWindow(image: blankCanvas(400, 300))
            let afterOpen = NSApp.activationPolicy()

            // 复刻 AppDelegate.closeAnnotationIfNeeded()：
            // 为了不再弹一次确认框，它显式把 delegate 置 nil 再 close()
            w1.delegate = nil
            w1.close()
            let afterProgrammatic = NSApp.activationPolicy()

            // 对照：走正常关窗（delegate 仍是自己 → windowWillClose 会跑）
            let w2 = AnnotationWindow(image: blankCanvas(400, 300))
            w2.close()
            let afterNormal = NSApp.activationPolicy()

            if afterProgrammatic == .regular && afterNormal == .accessory {
                Probe.bug("NEW-I",
                          "closeAnnotationIfNeeded() 置空 delegate 后关窗，跳过了 windowWillClose，"
                            + "激活策略永久停在 .regular",
                          "开窗后 \(afterOpen) → 程序化关窗后 \(afterProgrammatic)"
                            + "（正常关窗则为 \(afterNormal)）",
                          expect: "应回到 .accessory。否则：已有标注窗 → 再次截图 → "
                            + "若这次截图被取消（ESC）或没找到窗口，"
                            + "就再也不会有新窗口来重置策略，Dock 图标与菜单栏永久残留")
            } else {
                Probe.ok("NEW-I", "程序化关窗后激活策略正确",
                         "programmatic=\(afterProgrammatic) normal=\(afterNormal)")
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-J  虚线/点线箭头在 Layer B 上也被画成虚的 → 命中区被打断")
        // ─────────────────────────────────────────────────────────────
        do {
            func shaftHitRate(_ style: ArrowStyle) -> (hit: Int, total: Int) {
                let v = newCanvas(600, 300)
                v.currentTool = .arrow
                v.currentArrowStyle = style
                drag(v, from: CGPoint(x: 100, y: 150), to: CGPoint(x: 500, y: 150))
                var hit = 0, total = 0
                // 只扫箭杆区间（避开 x>452 的箭头头部，那里是实心填充）
                for x in stride(from: CGFloat(130), through: 440, by: 2) {
                    total += 1
                    if selects(v, at: CGPoint(x: x, y: 150)) { hit += 1 }
                }
                return (hit, total)
            }

            let solid = shaftHitRate(.default)
            let dashed = shaftHitRate(.dashedArrow)
            let dotted = shaftHitRate(.dottedDiamond)
            func pct(_ r: (hit: Int, total: Int)) -> Int {
                Int((Double(r.hit) / Double(max(r.total, 1)) * 100).rounded())
            }

            if pct(dashed) < 95 || pct(dotted) < 95 {
                Probe.bug("NEW-J",
                          "箭头线型被带进了 Layer B，命中区跟着变成虚线/点线",
                          "沿箭杆每 2pt 采样一次的命中率：实心 \(pct(solid))%"
                            + "、虚线 \(pct(dashed))%、点菱 \(pct(dotted))%"
                            + "（\(dashed.hit)/\(dashed.total)、\(dotted.hit)/\(dotted.total)）",
                          expect: "Layer B 只该表达「可点区域」，线型属于可见层。"
                            + "虚线/点线箭头的箭杆应接近 100% 可命中")
            } else {
                Probe.ok("NEW-J", "各种线型的命中率一致",
                         "实心 \(pct(solid))% / 虚线 \(pct(dashed))% / 点菱 \(pct(dotted))%")
            }
        }

        // ─────────────────────────────────────────────────────────────
        Probe.section("NEW-K  默认线宽 15 下线型是否还看得出来（README 承诺 6 种箭头样式）")
        // ─────────────────────────────────────────────────────────────
        do {
            func renderBytes(_ style: ArrowStyle, _ lw: CGFloat) -> [UInt8] {
                let v = newCanvas(600, 300)
                v.currentLineWidth = lw
                v.currentTool = .arrow
                v.currentArrowStyle = style
                drag(v, from: CGPoint(x: 100, y: 150), to: CGPoint(x: 500, y: 150))
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return [] }
                v.cacheDisplay(in: v.bounds, to: rep)
                guard let data = rep.bitmapData else { return [] }
                return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
            }

            // .default 与 .dashedArrow 只有 lineStyle 不同（都是实心三角头）
            let solid15 = renderBytes(.default, 15)
            let dashed15 = renderBytes(.dashedArrow, 15)
            let same15 = solid15 == dashed15 && !solid15.isEmpty

            // 对照：细线宽下两者应当可区分
            let solid3 = renderBytes(.default, 3)
            let dashed3 = renderBytes(.dashedArrow, 3)
            let same3 = solid3 == dashed3

            if same15 && !same3 {
                Probe.bug("NEW-K",
                          "默认线宽 15 下「虚线」箭头与「实心」渲染结果逐字节完全相同 → 线型不可见",
                          "线宽 15：实心与虚线渲染 \(same15 ? "完全一致" : "不同")；"
                            + "线宽 3：\(same3 ? "完全一致" : "可区分")。"
                            + "原因是 setLineCap(.round)：虚线 [8,4] 的点划线端帽各外扩 lw/2=7.5pt，"
                            + "8+15=23pt 的墨迹铺在 12pt 的周期上，空隙被填满",
                          expect: "两种线型在默认线宽下应渲染出不同结果"
                            + "（README 第 13/39 行承诺 6 种可区分样式）")
            } else {
                Probe.ok("NEW-K", "线型在默认线宽下可区分",
                         "lw15 same=\(same15), lw3 same=\(same3)")
            }
        }

        Probe.finish("probe_post_fix_audit")
    }

    // MARK: - 离屏渲染（无需窗口）

    /// 把视图离屏渲染后，读某个 AppKit 点（左下角原点）的亮度
    static func renderLuminance(_ v: AnnotationView, at p: CGPoint) -> CGFloat {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return -1 }
        v.cacheDisplay(in: v.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / max(v.bounds.width, 1)
        let sy = CGFloat(rep.pixelsHigh) / max(v.bounds.height, 1)
        let px = Int(p.x * sx)
        let py = Int((v.bounds.height - p.y - 0.5) * sy)
        guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
              let c = rep.colorAt(x: px, y: py) else { return -1 }
        return (c.redComponent + c.greenComponent + c.blueComponent) / 3
    }

    // MARK: - 视图树工具（用于驱动 AnnotationWindow 的工具栏）

    static func findCanvas(_ v: NSView) -> AnnotationView? {
        if let c = v as? AnnotationView { return c }
        for sub in v.subviews { if let c = findCanvas(sub) { return c } }
        return nil
    }

    static func buttons(in v: NSView) -> [NSButton] {
        var out: [NSButton] = []
        if let b = v as? NSButton { out.append(b) }
        for sub in v.subviews { out.append(contentsOf: buttons(in: sub)) }
        return out
    }

    static func popUps(in v: NSView) -> [NSPopUpButton] {
        var out: [NSPopUpButton] = []
        if let p = v as? NSPopUpButton { out.append(p) }
        for sub in v.subviews { out.append(contentsOf: popUps(in: sub)) }
        return out
    }

    static func findButton(titled title: String, in v: NSView) -> NSButton? {
        buttons(in: v).first { $0.title == title }
    }
}
