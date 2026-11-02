// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nits",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NitsCore", targets: ["NitsCore"]),
        .executable(name: "Nits", targets: ["NitsApp"]),
        .executable(name: "nitsctl", targets: ["nitsctl"]),
    ],
    targets: [
        // Objective-C shim for the private CGVirtualDisplay classes, reached via the
        // Objective-C runtime so nothing private is linked.
        .target(
            name: "NitsPrivate",
            path: "Sources/NitsPrivate",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .target(
            name: "NitsCore",
            dependencies: ["NitsPrivate"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NitsApp",
            dependencies: ["NitsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "nitsctl",
            dependencies: ["NitsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Stock Command Line Tools ships neither XCTest nor the Swift Testing macro
        // plugin, so the suite is a normal executable with a tiny harness. It needs no
        // Xcode and runs with `swift run nits-selftest`.
        .executableTarget(
            name: "NitsSelfTest",
            dependencies: ["NitsCore"],
            path: "Tests/NitsSelfTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
