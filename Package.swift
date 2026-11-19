// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Flash",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared by the app and the hook: redaction, secret patterns, what a
        // hook payload keeps. No AppKit, so the hook stays a small binary.
        .target(
            name: "FlashCore",
            path: "Sources/FlashCore"
        ),
        .executableTarget(
            name: "Flash",
            dependencies: ["FlashCore"],
            path: "Sources/Flash"
        ),
        // Ships as Flash.app/Contents/MacOS/flash-agent-hook.
        .executableTarget(
            name: "FlashAgentHook",
            dependencies: ["FlashCore"],
            path: "Sources/FlashAgentHook"
        ),
        .testTarget(
            name: "FlashCoreTests",
            dependencies: ["FlashCore"],
            path: "Tests/FlashCoreTests"
        ),
    ]
)
