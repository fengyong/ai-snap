// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISnap",
    // v14：ScreenCaptureKit 的 SCScreenshotManager 需要 macOS 14.0+
    // （旧路径 CGWindowListCreateImage 自 14.0 起 deprecated，15.0 起 obsolete）
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AISnap",
            path: "Sources"
        )
    ]
)
