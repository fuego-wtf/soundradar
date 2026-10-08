// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoundRadar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "SoundRadar", path: "Sources/SoundRadar")
    ]
)
