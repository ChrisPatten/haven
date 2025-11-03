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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "HavenUI",
            dependencies: [],
            path: "Sources/HavenUI"
        )
    ]
)
