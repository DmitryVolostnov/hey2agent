// swift-tools-version:6.0
import PackageDescription

// Shared by the Mac HUD (server) and the iPhone remote (client): message types and an
// encrypted local-network connection. Nothing goes through the internet.
let package = Package(
    name: "VoiceLoopLink",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [.library(name: "VoiceLoopLink", targets: ["VoiceLoopLink"])],
    targets: [
        .target(name: "VoiceLoopLink", path: "Sources/VoiceLoopLink"),
        .testTarget(name: "VoiceLoopLinkTests", dependencies: ["VoiceLoopLink"], path: "Tests"),
    ],
    swiftLanguageModes: [.v5]
)
