import Cocoa

/// 截图覆盖层的窗口外观。
///
/// 主屏的可交互覆盖层与副屏的只读覆盖层**必须用同一份配置** ——
/// 它们本质是同一种东西（铺满整屏、画一张冻结帧）。分头写、改一处漏一处的
/// 后果是某块屏表现异常，而且只在多屏机器上才看得见。
///
/// ## 为什么背景必须是透明的（而不是不透明黑）
///
/// 窗口的 `backgroundColor` 由 WindowServer 在 **contentView 绘制之前**填充。
/// 也就是说，从「窗口上屏」到「冻结帧画好」之间存在一段空隙，那段空隙里
/// 屏幕上显示的就是 `backgroundColor`。
///
/// 上一版用的是 `isOpaque = true` + `.black`，于是这段空隙就是**全屏纯黑**——
/// 用户看到的是一次黑闪。它有多长取决于首帧成本：全屏冻结帧是一位
/// 22–56 MB 的位图，14 寸内屏上光是「贴冻结帧 + 压暗」就要 12 ms（超 120 Hz
/// 的 8.33 ms 预算），再加大图的首次上传与合成，足够被眼睛抓住。
///
/// 改成透明之后，同样的空隙里透出的是**下方的真实屏幕**。而冻结帧本来就是
/// 真实屏幕的快照 —— 两者几乎一致，用户看不出差别。
/// 这比「想办法把首帧画得更快」可靠得多：无论首帧多慢，都不会黑。
///
/// - Note: 曾试过「`orderFront` 之前先同步绘制首帧」来填掉这段空隙，
///   但实测**窗口未上屏时 `display()` / `displayIfNeeded()` 都是 no-op**
///   （没有 window device，view 根本画不了，`drawCount` 始终为 0）。
///   所以只能从「空隙里显示什么」入手，而不是「把空隙填掉」。
enum OverlayWindowStyle {

    /// 应用到一个覆盖层窗口。主屏的可交互窗与副屏的只读窗都走这里。
    static func apply(to window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 高于菜单栏（.mainMenu = 24）：覆盖层要盖住菜单栏，
        // 否则用户会觉得选区靠上时被菜单栏挤掉一块。
        window.level = .statusBar + 1
    }
}
