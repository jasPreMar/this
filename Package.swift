// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "This",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "This",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources/A4.wav"),
                .process("Resources/C5.wav"),
                .copy("Resources/AppIcon.icns"),
                .process("Resources/StatusBarIcon.png"),
                .process("Resources/StatusBarIcon@2x.png"),
                .process("Resources/StatusBarIcon@3x.png"),
            ],
            // Embed Info.plist so macOS shows proper privacy descriptions in TCC dialogs.
            // Run `swift build` from the package root so the relative path resolves correctly.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Info.plist",
                    // Sparkle.framework is embedded at Contents/Frameworks at runtime
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        )
    ]
)
