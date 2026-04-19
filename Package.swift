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
        .library(name: "SidetoneTestSupport", targets: ["SidetoneTestSupport"]),
        .library(name: "SidetoneUI", targets: ["SidetoneUI"]),
        .executable(name: "SidetoneMac", targets: ["SidetoneMac"]),
    ],
    targets: [
        .target(
            name: "SidetoneCore",
            path: "Packages/SidetoneCore/Sources/SidetoneCore",
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
            dependencies: ["SidetoneCore", "SidetoneUI"],
            path: "Apps/Sidetone-Mac",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SidetoneCoreTests",
            dependencies: ["SidetoneCore", "SidetoneTestSupport"],
            path: "Packages/SidetoneCore/Tests/SidetoneCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
