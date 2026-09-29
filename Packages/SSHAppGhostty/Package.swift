// swift-tools-version: 6.0
import PackageDescription

/// Test-only seams compile into Debug builds and into device test runs that
/// pass VT_TEST_HOOKS explicitly; App Store (Release archive) builds omit them.
let testHooks: [SwiftSetting] = [.define("VT_TEST_HOOKS", .when(configuration: .debug))]

let package = Package(
    name: "SSHAppGhostty",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        // App and hosted tests must share one product closure. Overlapping
        // products can load duplicate ObjC classes from the same targets.
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    targets: [
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyVT"],
            path: "Sources/GhosttyTerminal",
            swiftSettings: testHooks
        ),
        .target(
            name: "CGhosttyVT",
            dependencies: ["libghosttyvt"],
            path: "Sources/CGhosttyVT",
            cSettings: [.define("VT_TEST_HOOKS", .when(configuration: .debug))]
        ),
        .target(
            name: "GhosttyVT",
            dependencies: ["CGhosttyVT"],
            path: "Sources/GhosttyVT",
            swiftSettings: testHooks,
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("IOSurface"),
            ]
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal", "GhosttyVT"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(
            name: "libghosttyvt",
            path: "../../Frameworks/GhosttyVT.xcframework"
        ),
    ]
)
