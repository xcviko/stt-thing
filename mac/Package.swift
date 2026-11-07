// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "STTThing",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "STTThing",
            path: "Sources/STTThing",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
