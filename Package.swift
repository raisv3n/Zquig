// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zquig",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "Zquig", path: "Sources/Zquig")
    ]
)
