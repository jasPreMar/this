// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HyperPointer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HyperPointer",
            path: "Sources"
        )
    ]
)
