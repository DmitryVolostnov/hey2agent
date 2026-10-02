// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceLoopHUD",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "VoiceLoopHUD", path: "Sources/VoiceLoopHUD")
    ]
)
