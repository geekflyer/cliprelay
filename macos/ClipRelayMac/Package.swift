// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "clipboard-sync-mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipRelay", targets: ["ClipRelay"])
    ],
    targets: [
        .executableTarget(
            name: "ClipRelay",
            path: "Sources"
        ),
        .testTarget(
            name: "ClipRelayTests",
            dependencies: ["ClipRelay"],
            path: "Tests/ClipRelayTests"
        )
    ]
)
