import Cocoa
import ScreenCaptureKit

// SCK 自检：V4（Retina 分辨率）+ V5（权限行为）+ V1 部分（输出尺寸一致性）
if !CGPreflightScreenCaptureAccess() {
    print("NO_PERMISSION: 终端无屏幕录制权限，无法自动实测。请手动按 V1–V7 清单验证。")
    exit(0)
}
print("权限 OK，开始自检……")

// V4: 截取屏幕左上角 200×200 点，看输出像素是 400×400（Retina）还是 200×200 或 1920×1080
let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
let sema = DispatchSemaphore(value: 0)

if #available(macOS 15.2, *) {
    SCScreenshotManager.captureImage(in: rect) { image, error in
        if let error {
            print("V4 captureImage(in:) 失败: \(error)")
        } else if let img = image {
            print("V4 [15.2+ 路径] 请求 200×200 点 → 输出 \(img.width)×\(img.height) px")
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            print(img.width == Int(200 * scale)
                  ? "V4 ✅ 原生 Retina 分辨率（×\(scale)）"
                  : "V4 ❌ 非 Retina 尺寸！15.2 路径需要显式设置尺寸或改走 filter 路径")
        }
        sema.signal()
    }
} else {
    print("系统 < 15.2，跳过 in-rect 路径测试")
    sema.signal()
}
sema.wait()

// 对照组：filter 路径（显式宽高）
let sema2 = DispatchSemaphore(value: 0)
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
    guard let content, let display = content.displays.first else {
        print("filter 对照组：拿不到 display: \(error.map(String.init(describing:)) ?? "nil")")
        sema2.signal(); return
    }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let own = content.windows.filter { $0.owningApplication?.processID == Int32(ownPID) }
    let filter = SCContentFilter(display: display, excludingWindows: own)
    let config = SCStreamConfiguration()
    config.captureResolution = .best
    config.showsCursor = false
    config.sourceRect = CGRect(x: 0, y: 0, width: 200, height: 200)
    let scale = CGFloat(filter.pointPixelScale)
    config.width = Int((200 * scale).rounded())
    config.height = Int((200 * scale).rounded())
    print("filter 对照组：pointPixelScale=\(scale)，请求输出 \(config.width)×\(config.height)")
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
        if let error {
            print("filter 对照组失败: \(error)")
        } else if let img = image {
            print("filter 对照组输出 \(img.width)×\(img.height) px",
                  img.width == config.width ? "✅" : "❌")
        }
        sema2.signal()
    }
}
sema2.wait()
print("自检完成")
