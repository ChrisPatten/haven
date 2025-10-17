// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "haven-hostagent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "haven-hostagent", targets: ["HostAgentApp"]),
        .library(name: "HostHTTP", targets: ["HostHTTP"]),
        .library(name: "IMessages", targets: ["IMessages"]),
        .library(name: "OCR", targets: ["OCR"]),
        .library(name: "FSWatch", targets: ["FSWatch"]),
        .library(name: "Core", targets: ["Core"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.58.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.23.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "Yams"
            ],
            path: "Sources/Core"
        ),
        .target(
            name: "HostHTTP",
            dependencies: [
                "Core",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/HostHTTP"
        ),
        .target(
            name: "IMessages",
            dependencies: [
                "Core",
                "OCR",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/IMessages",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "OCR",
            dependencies: [
                "Core",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/OCR",
            linkerSettings: [
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .target(
            name: "FSWatch",
            dependencies: [
                "Core",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio")
            ],
            path: "Sources/FSWatch",
            linkerSettings: [
                .linkedFramework("CoreServices")
            ]
        ),
        .executableTarget(
            name: "HostAgentApp",
            dependencies: [
                "Core",
                "HostHTTP",
                "IMessages",
                "OCR",
                "FSWatch"
            ],
            path: "Sources/HostAgentApp"
        ),
        .testTarget(
            name: "HostAgentTests",
            dependencies: [
                "Core",
                "HostHTTP",
                "IMessages",
                "OCR",
                "FSWatch",
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/HostAgentTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
