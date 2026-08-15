// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "MacTime",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MacTime",
            path: "Sources/MacTime",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
