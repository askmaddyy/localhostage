// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "localhostage",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "localhostage", path: "Sources")]
)
