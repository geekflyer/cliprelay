// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "clipboard-sync-mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipRelay", targets: ["ClipRelay"]),
        .executable(name: "ClipRelaySmokeCLI", targets: ["ClipRelaySmokeCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "ClipRelayCore",
            path: "Sources",
            exclude: [
                "App",
                "BLE",
                "Clipboard",
                "ClipRelay",
                "ClipRelaySmokeCLI",
                "Pairing/DeviceSettingsProvider.swift",
                "Pairing/PairingWindowController.swift",
                "Protocol",
                "TCP",
                "Telemetry"
            ],
            sources: [
                "Crypto",
                "Pairing/PairingManager.swift",
                "Security",
                "Smoke"
            ]
        ),
        .executableTarget(
            name: "ClipRelay",
            dependencies: [
                "ClipRelayCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            exclude: [
                "ClipRelaySmokeCLI",
                "Crypto",
                "Security",
                "Smoke",
                "Pairing/PairingManager.swift"
            ],
            sources: [
                "App",
                "BLE",
                "Clipboard",
                "ClipRelay/main.swift",
                "Pairing/DeviceSettingsProvider.swift",
                "Pairing/PairingWindowController.swift",
                "Protocol",
                "TCP",
                "Telemetry"
            ]
        ),
        .executableTarget(
            name: "ClipRelaySmokeCLI",
            dependencies: ["ClipRelayCore"],
            path: "Sources",
            exclude: [
                "App",
                "BLE",
                "Clipboard",
                "ClipRelay",
                "Crypto",
                "Pairing",
                "Protocol",
                "Security",
                "Smoke",
                "TCP",
                "Telemetry"
            ],
            sources: ["ClipRelaySmokeCLI/main.swift"]
        ),
        .testTarget(
            name: "ClipRelayTests",
            dependencies: ["ClipRelay", "ClipRelayCore"],
            path: "Tests/ClipRelayTests"
        )
    ]
)
