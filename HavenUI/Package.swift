// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "haven-ui",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "HavenUI",
            targets: ["HavenUI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
    ],
    targets: [
        .executableTarget(
            name: "HavenUI",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/HavenUI",
            resources: [
                // Processes the Resources directory so Assets.xcassets (AppIcon) is bundled
                .process("Resources")
            ]
        )
    ]
)
