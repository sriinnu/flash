// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Flash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Flash",
            path: "Sources/Flash"
        )
    ]
)
