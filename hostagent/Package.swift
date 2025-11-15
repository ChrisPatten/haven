// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "haven-hostagent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "HavenCore",
            targets: ["HavenCore"]
        ),
        .library(
            name: "CollectorHandlers",
            targets: ["CollectorHandlers"]
        ),
        .library(
            name: "HostAgentEmail",
            targets: ["HostAgentEmail"]
        ),
        .library(
            name: "OCR",
            targets: ["OCR"]
        ),
        .library(
            name: "Entity",
            targets: ["Entity"]
        ),
        .library(
            name: "FSWatch",
            targets: ["FSWatch"]
        ),
        .library(
            name: "Face",
            targets: ["Face"]
        ),
        .library(
            name: "Caption",
            targets: ["Caption"]
        ),
        .plugin(
            name: "GenerateBuildInfo",
            targets: ["GenerateBuildInfo"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/ChrisPatten/mailcore2.git", branch: "master"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/steipete/Demark.git", from: "1.0.0"),
        .package(url: "https://github.com/Kitura/swift-html-entities.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "HavenCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Demark", package: "Demark"),
                .product(name: "HTMLEntities", package: "swift-html-entities")
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
            name: "Caption",
            dependencies: ["HavenCore"],
            path: "Sources/Caption"
        ),
        .executableTarget(
            name: "CaptionComparison",
            dependencies: ["Caption", "HavenCore", .product(name: "Yams", package: "Yams")],
            path: "Sources/CaptionComparison"
        ),
        .target(
            name: "Email",
            dependencies: ["HavenCore", "OCR", .product(name: "SwiftSoup", package: "SwiftSoup"), .product(name: "Demark", package: "Demark"), .product(name: "HTMLEntities", package: "swift-html-entities")],
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
            name: "CollectorHandlers",
            dependencies: [
                "HavenCore",
                "HostAgentEmail",
                "IMAP",
                "OCR",
                "Entity",
                "Face",
                "Caption",
                "Email",
                "FSWatch"
            ],
            path: "Sources/CollectorHandlers"
        ),
        .plugin(
            name: "GenerateBuildInfo",
            capability: .buildTool()
        ),
        .target(
            name: "HostAgentEmail",
            dependencies: [
                "HavenCore",
                "Email",
                "OCR",
                "Entity",
                "Face",
                "Caption"
            ],
            path: "Sources/HostAgent",
            sources: [
                "Collectors",
                "Submission",
                "Enrichment",
                "DocumentTypes.swift",
                "EnrichmentOrchestrator.swift"
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
        ),
        .testTarget(
            name: "IMessagesTests",
            dependencies: ["CollectorHandlers", "HostAgentEmail", "HavenCore"],
            path: "Tests/IMessagesTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
