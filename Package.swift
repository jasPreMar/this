// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "This",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "ThisCore",
            path: "Sources/ThisCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "This",
            dependencies: [
                "ThisCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            exclude: ["Info.plist", "ThisCore"],
            resources: [
                .process("Resources/A4.wav"),
                .process("Resources/C5.wav"),
                .copy("Resources/AppIcon.icns"),
                .process("Resources/StatusBarIcon.png"),
                .process("Resources/StatusBarIcon@2x.png"),
                .process("Resources/StatusBarIcon@3x.png"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Info.plist",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .executableTarget(
            name: "ThisTests",
            dependencies: ["ThisCore"],
            path: "Tests/ThisTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
