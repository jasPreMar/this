// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HyperPointer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2"),
    ],
    targets: [
        .executableTarget(
            name: "HyperPointer",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources"
        )
    ]
)
