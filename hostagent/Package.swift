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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
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
            path: "Sources/HavenCore"
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
            path: "Sources/Entity"
        ),
        
        // Face: Vision framework face detection
        .target(
            name: "Face",
            dependencies: ["HavenCore"],
            path: "Sources/Face"
        ),
        
        // IMessages: Messages.app database collector
        .target(
            name: "IMessages",
            dependencies: [
                "HavenCore",
                "OCR",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/IMessages"
        ),
        
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
                "IMessages",
                "FSWatch",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio")
            ],
            path: "Sources/HostHTTP"
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
        .testTarget(
            name: "IMessagesTests",
            dependencies: ["IMessages", "HavenCore"],
            path: "Tests/IMessagesTests",
            resources: [.copy("Fixtures")]
        ),
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
