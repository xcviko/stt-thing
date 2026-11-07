// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stt-thing",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "stt-thing", targets: ["STTThing"])
    ],
    targets: [
        .executableTarget(
            name: "STTThing",
            path: "Sources/STTThing",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
