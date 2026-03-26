// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISnap",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AISnap",
            path: "Sources"
        )
    ]
)
