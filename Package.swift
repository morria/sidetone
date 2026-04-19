// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sidetone",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SidetoneCore", targets: ["SidetoneCore"]),
        .library(name: "SidetoneServer", targets: ["SidetoneServer"]),
        .library(name: "SidetoneTestSupport", targets: ["SidetoneTestSupport"]),
        .library(name: "SidetoneUI", targets: ["SidetoneUI"]),
        .executable(name: "SidetoneMac", targets: ["SidetoneMac"]),
    ],
    dependencies: [
        // Server side only. Clients use Foundation's URLSession +
        // URLSessionWebSocketTask and don't pull NIO at all.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SidetoneCore",
            path: "Packages/SidetoneCore/Sources/SidetoneCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SidetoneServer",
            dependencies: [
                "SidetoneCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Packages/SidetoneServer/Sources/SidetoneServer",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SidetoneTestSupport",
            dependencies: ["SidetoneCore"],
            path: "Packages/SidetoneTestSupport/Sources/SidetoneTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SidetoneUI",
            dependencies: ["SidetoneCore"],
            path: "Packages/SidetoneUI/Sources/SidetoneUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SidetoneMac",
            dependencies: ["SidetoneCore", "SidetoneServer", "SidetoneUI"],
            path: "Sidetone",
            exclude: ["Assets.xcassets"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SidetoneCoreTests",
            dependencies: ["SidetoneCore", "SidetoneTestSupport"],
            path: "Packages/SidetoneCore/Tests/SidetoneCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SidetoneServerTests",
            dependencies: ["SidetoneServer", "SidetoneCore", "SidetoneTestSupport"],
            path: "Packages/SidetoneServer/Tests/SidetoneServerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
