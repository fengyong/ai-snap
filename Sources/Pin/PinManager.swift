import Cocoa

/// 贴图管理：创建、记录、批量关闭。
///
/// 单独抽一层的原因：贴图的**生命周期**不能只靠窗口自己管 ——
/// 窗口被 `close()` 之后若还留在数组里，就会变成幽灵引用；
/// 而「关闭全部贴图」又需要能拿到所有窗口。把这两件事收到一处。
final class PinManager {
    static let shared = PinManager()

    private var pins: [PinWindow] = []

    private init() {}

    /// 已打开的贴图数量。
    var count: Int { pins.count }

    /// 把一张图钉在屏幕上。
    ///
    /// - Parameters:
    ///   - image: 要钉住的图
    ///   - preferredOrigin: 期望的左上角位置（屏幕坐标，左下原点）；传 nil 则用鼠标位置
    @discardableResult
    func pin(_ image: NSImage, at preferredOrigin: NSPoint? = nil) -> PinWindow {
        let size = PinManager.initialSize(for: image)
        let origin = clampToScreen(
            preferredOrigin ?? PinManager.defaultOrigin(for: size),
            size: size
        )

        let pin = PinWindow(image: image,
                            frame: NSRect(origin: origin, size: size))
        // 登记由管理器独占：窗口自己 `register(self)` 会让所有权含糊不清，
        // 而且 pin() 里再 append 一次就重复登记了（close 时只移除一个，留下幽灵引用）
        pins.append(pin)
        pin.orderFrontRegardless()      // 显示但不抢焦点
        return pin
    }

    func unregister(_ pin: PinWindow) {
        pins.removeAll { $0 === pin }
    }

    func closeAll() {
        // 先复制一份再遍历：close() 会回调 unregister 改动 pins
        for pin in pins { pin.close() }
        pins.removeAll()
    }

    // MARK: - 位置与初始尺寸

    /// 初始尺寸：超过屏幕可视区就等比缩到能放下，避免一钉就铺满整屏。
    private static func initialSize(for image: NSImage) -> NSSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return NSSize(width: 200, height: 150) }

        guard let screen = NSScreen.main?.visibleFrame else { return size }
        let maxW = screen.width * 0.8
        let maxH = screen.height * 0.9
        let scale = min(1, min(maxW / size.width, maxH / size.height))
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    /// 默认位置：鼠标附近略偏右下，连续贴多张时按扇形错开，免得完全叠在一起。
    private static func defaultOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let offset = CGFloat(shared.count % 6) * 24
        return NSPoint(x: mouse.x + 16 + offset, y: mouse.y - size.height - 16 - offset)
    }

    /// 夹到鼠标所在屏幕的可视区内，保证贴图整体可见（贴到屏外就再也点不到了）。
    private func clampToScreen(_ origin: NSPoint, size: NSSize) -> NSPoint {
        // 用原点位置找屏幕；找不到就用主屏
        let target = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        guard let visible = target?.visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.maxX - size.width, visible.minX)),
            y: min(max(origin.y, visible.minY), max(visible.maxY - size.height, visible.minY))
        )
    }

    /// 贴图数量变化时给菜单项用（供 AppDelegate 决定「关闭全部贴图」是否可点）。
    var hasPins: Bool { !pins.isEmpty }
}
