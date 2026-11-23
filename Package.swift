// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DriveSync",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "DriveSync", path: "Sources")]
)
