// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHAppGhostty",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    dependencies: [
        // Pinned to an immutable commit; the comment records the release it maps to.
        .package(
            url: "https://github.com/Lakr233/MSDisplayLink.git",
            revision: "1ba3e769b734e456317fa7e45321fa7f53eefb67" // MSDisplayLink 2.1.0
        ),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal"
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(
            name: "libghostty",
            path: "../../Frameworks/GhosttyKit.xcframework"
        ),
    ]
)
