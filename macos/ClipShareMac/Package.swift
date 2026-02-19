// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "clipboard-sync-mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipShareMac", targets: ["ClipShareMac"])
    ],
    targets: [
        .executableTarget(
            name: "ClipShareMac",
            path: "Sources"
        )
    ]
)
