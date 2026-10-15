// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SmartPanel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SmartPanel", path: "Sources/SmartPanel")
    ]
)
