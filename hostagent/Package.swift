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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/MailCore/mailcore2.git", branch: "master"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0")
    ],
    targets: [
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
        .target(
            name: "OCR",
            dependencies: ["HavenCore"],
            path: "Sources/OCR"
        ),
        .target(
            name: "Entity",
            dependencies: ["HavenCore"],
            path: "Sources/Entity",
            exclude: ["README.md"]
        ),
        .target(
            name: "Face",
            dependencies: ["HavenCore"],
            path: "Sources/Face"
        ),
        .target(
            name: "Email",
            dependencies: ["HavenCore"],
            path: "Sources/Email"
        ),
        .target(
            name: "IMAP",
            dependencies: [
                "HavenCore",
                .product(name: "MailCore2", package: "mailcore2")
            ],
            path: "Sources/IMAP"
        ),
        .target(
            name: "FSWatch",
            dependencies: ["HavenCore"],
            path: "Sources/FSWatch"
        ),
        .target(
            name: "HostHTTP",
            dependencies: [
                "HavenCore",
                "HostAgentEmail",
                "IMAP",
                "OCR",
                "Entity",
                "Face",
                "Email",
                "FSWatch",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
            path: "Sources/HostHTTP",
            exclude: ["Handlers/EmailLocalHandler.swift", "Handlers/EmailLocalHandler.swift.removed"],
            resources: [
                .process("API/openapi.yaml")
            ],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .plugin(
            name: "GenerateBuildInfo",
            capability: .buildTool()
        ),
        .executableTarget(
            name: "HostAgent",
            dependencies: [
                "HavenCore",
                "HostHTTP",
                "HostAgentEmail",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/HostAgent",
            exclude: ["Collectors", "Submission"]
        ),
        .target(
            name: "HostAgentEmail",
            dependencies: [
                "HavenCore",
                "Email"
            ],
            path: "Sources/HostAgent",
            exclude: ["main.swift"],
            sources: [
                "Collectors",
                "Submission"
            ]
        ),
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
            name: "FSWatchTests",
            dependencies: ["FSWatch", "HavenCore"],
            path: "Tests/FSWatchTests"
        ),
        .testTarget(
            name: "EmailTests",
            dependencies: ["Email", "HavenCore"],
            path: "Tests/EmailTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HostHTTPTests",
            dependencies: ["HostHTTP", "HostAgentEmail", "HavenCore"],
            path: "Tests/HostHTTPTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SubmissionTests",
            dependencies: ["HostAgentEmail", "Email", "HavenCore"],
            path: "Tests/SubmissionTests"
        ),
        .testTarget(
            name: "IMAPTests",
            dependencies: ["IMAP", "HavenCore"],
            path: "Tests/IMAPTests"
        ),
        .testTarget(
            name: "HostAgentTests",
            dependencies: ["HostAgentEmail", "HavenCore"],
            path: "Tests/HostAgentTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
