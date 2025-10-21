// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "haven-hostagent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "hostagent",
            targets: ["HostAgent"]
        ),
        .library(
            name: "HavenCore",
            targets: ["HavenCore"]
        ),
        .plugin(
            name: "GenerateBuildInfo",
            targets: ["GenerateBuildInfo"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
    // GRDB removed: not used by any current target
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        // Core: Configuration, logging, auth, shared utilities
        .target(
            name: "HavenCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/HavenCore",
            plugins: ["GenerateBuildInfo"]
        ),
        
        // OCR: Vision framework integration
        .target(
            name: "OCR",
            dependencies: ["HavenCore"],
            path: "Sources/OCR"
        ),
        
        // Entity: Natural Language entity extraction
        .target(
            name: "Entity",
            dependencies: ["HavenCore"],
            path: "Sources/Entity",
            exclude: ["README.md"]
        ),
        
        // Face: Vision framework face detection
        .target(
            name: "Face",
            dependencies: ["HavenCore"],
            path: "Sources/Face"
        ),
        
        // IMessages target intentionally omitted (no Sources/IMessages in this repo)
        
        // FSWatch: File system monitoring
        .target(
            name: "FSWatch",
            dependencies: ["HavenCore"],
            path: "Sources/FSWatch"
        ),
        
        // HostHTTP: SwiftNIO HTTP server
        .target(
            name: "HostHTTP",
            dependencies: [
                "HavenCore",
                "OCR",
                "Entity",
                "Face",
                "FSWatch",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio")
            ],
            path: "Sources/HostHTTP"
        ),
        
        // Build plugin to generate BuildInfo before compilation
        .plugin(
            name: "GenerateBuildInfo",
            capability: .buildTool()
        ),
        
        // Main executable
        .executableTarget(
            name: "HostAgent",
            dependencies: [
                "HavenCore",
                "HostHTTP",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/HostAgent"
        ),
        
        // Tests
        .testTarget(
            name: "HavenCoreTests",
            dependencies: ["HavenCore"],
            path: "Tests/HavenCoreTests"
        ),
        .testTarget(
            name: "OCRTests",
            dependencies: ["OCR", "HavenCore"],
            path: "Tests/OCRTests",
            resources: [.copy("Fixtures")]
        ),
        // IMessagesTests omitted (test fixture retained in tree but not part of Package.swift)
        .testTarget(
            name: "FSWatchTests",
            dependencies: ["FSWatch", "HavenCore"],
            path: "Tests/FSWatchTests"
        ),
        .testTarget(
            name: "HostHTTPTests",
            dependencies: ["HostHTTP", "HavenCore"],
            path: "Tests/HostHTTPTests"
        )
    ]
)
