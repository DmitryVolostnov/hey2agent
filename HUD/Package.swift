// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceLoopHUD",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../Link")],
    targets: [
        .executableTarget(
            name: "VoiceLoopHUD",
            dependencies: [.product(name: "VoiceLoopLink", package: "Link")],
            path: "Sources/VoiceLoopHUD"
        )
    ]
)
