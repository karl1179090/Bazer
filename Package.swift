// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bazer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BazerCore", targets: ["BazerCore"]),
        .library(name: "RazerProtocol", targets: ["RazerProtocol"]),
        .library(name: "LogitechHIDPP", targets: ["LogitechHIDPP"]),
        .library(name: "BazerHID", targets: ["BazerHID"]),
        .library(name: "BazerDrivers", targets: ["BazerDrivers"]),
        .library(name: "BazerBluetooth", targets: ["BazerBluetooth"]),
        .executable(name: "BluetoothAudioProbe", targets: ["BluetoothAudioProbe"]),
        .executable(name: "HIDProbe", targets: ["HIDProbe"]),
        .executable(name: "BazerApp", targets: ["BazerApp"])
    ],
    targets: [
        .target(name: "BazerCore"),
        .target(name: "BazerBluetooth", dependencies: ["BazerCore"], linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreBluetooth"), .linkedFramework("IOKit")]),
        .executableTarget(name: "BluetoothAudioProbe", dependencies: ["BazerBluetooth", "BazerCore"]),
        .target(name: "RazerProtocol"),
        .target(name: "LogitechHIDPP"),
        .target(name: "BazerHID", dependencies: ["BazerCore", "LogitechHIDPP"]),
        .target(name: "BazerDrivers", dependencies: ["BazerCore", "BazerHID", "RazerProtocol", "LogitechHIDPP"]),
        .executableTarget(name: "HIDProbe", dependencies: ["BazerCore", "BazerHID", "BazerDrivers", "LogitechHIDPP"]),
        .executableTarget(name: "BazerApp", dependencies: ["BazerCore", "BazerHID", "BazerDrivers", "BazerBluetooth"]),
        .testTarget(name: "BazerBluetoothTests", dependencies: ["BazerBluetooth", "BazerCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "BazerCoreTests", dependencies: ["BazerCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RazerProtocolTests", dependencies: ["RazerProtocol"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LogitechHIDPPTests", dependencies: ["LogitechHIDPP"]),
        .testTarget(name: "BazerHIDTests", dependencies: ["BazerHID", "BazerCore", "RazerProtocol"]),
        .testTarget(name: "BazerDriversTests", dependencies: ["BazerDrivers", "BazerCore", "BazerHID", "RazerProtocol"], resources: [.copy("Fixtures")]),
        .testTarget(name: "HIDProbeTests", dependencies: ["HIDProbe"]),
        .testTarget(name: "BazerAppTests", dependencies: ["BazerApp", "BazerCore", "BazerDrivers", "BazerHID", "BazerBluetooth"])
    ],
    swiftLanguageModes: [.v6]
)
