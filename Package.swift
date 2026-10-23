// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Eufynized",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EufyKit", targets: ["EufyKit"]),
        .library(name: "EufynizedKit", targets: ["EufynizedKit"]),
        .executable(name: "eufynized-probe", targets: ["eufynized-probe"]),
        .executable(name: "eufynized-ptz", targets: ["eufynized-ptz"]),
        .executable(name: "eufynized-params", targets: ["eufynized-params"]),
        .executable(name: "eufynized-settings", targets: ["eufynized-settings"]),
        .executable(name: "eufynized-login", targets: ["eufynized-login"]),
        .executable(name: "eufynized-discover", targets: ["eufynized-discover"]),
        .executable(name: "eufynized-connect", targets: ["eufynized-connect"]),
        .executable(name: "eufynized-snapshot", targets: ["eufynized-snapshot"]),
        .executable(name: "eufynized-cipher", targets: ["eufynized-cipher"]),
        .executable(name: "eufynized-l2snapshot", targets: ["eufynized-l2snapshot"]),
        .executable(name: "eufynized-fps", targets: ["eufynized-fps"]),
        .executable(name: "eufynized-events", targets: ["eufynized-events"]),
        .executable(name: "eufynized-health", targets: ["eufynized-health"]),
        .executable(name: "eufynized-bridge", targets: ["eufynized-bridge"]),
    ],
    dependencies: [
        // Linux only (the Home Assistant add-on): CryptoKit's open-source twin, plus AES block / RSA extras.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    ],
    targets: [
        // Direct Eufy protocol: cloud sign-in, device list, and (later) HomeBase P2P.
        .target(name: "EufyKit", dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        // Home Assistant + go2rtc bridge.
        .target(name: "EufynizedKit", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-probe", dependencies: ["EufynizedKit"]),
        .executableTarget(name: "eufynized-ptz", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-params", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-settings", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-login", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-discover", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-connect", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-snapshot", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-cipher", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-l2snapshot", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-fps", dependencies: ["EufyKit", "EufynizedKit"]),
        .executableTarget(name: "eufynized-events", dependencies: ["EufyKit"]),
        .executableTarget(name: "eufynized-health", dependencies: ["EufyKit"]),
        // The Home Assistant add-on's server (Linux on the Pi; also builds on macOS).
        .executableTarget(name: "eufynized-bridge", dependencies: ["EufyKit"]),
        .testTarget(name: "EufynizedKitTests", dependencies: ["EufynizedKit"]),
        .testTarget(name: "EufyKitTests", dependencies: ["EufyKit"]),
    ],
    swiftLanguageModes: [.v5]
)
