// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure protocol code: framing, commands and reply parsing. No Bluetooth, fully testable.
        .target(name: "EarshotCore"),
        // The menu-bar app: IOBluetooth link, state store and SwiftUI.
        .executableTarget(
            name: "Earshot",
            dependencies: ["EarshotCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(name: "EarshotCoreTests", dependencies: ["EarshotCore"]),
    ]
)
