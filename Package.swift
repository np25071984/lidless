// swift-tools-version:5.9
//
// build.sh builds the `lidless` binary into build/; `swift test` runs the
// decision logic.

import PackageDescription

let package = Package(
    name: "lidless",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "lidless",
            path: "Sources/Lidless",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "lidlessTests",
            dependencies: ["lidless"],
            path: "Tests/lidlessTests"
        ),
    ]
)
