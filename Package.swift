// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "todo-notch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "todo-notch", path: "Sources")
    ]
)
