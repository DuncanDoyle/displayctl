// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DisplayControl",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DisplayControlCore", targets: ["DisplayControlCore"]),
        .executable(name: "displayctl", targets: ["displayctl"]),
    ],
    targets: [
        .target(name: "DisplayControlCore"),
        .executableTarget(name: "displayctl", dependencies: ["DisplayControlCore"]),
        .testTarget(name: "DisplayControlCoreTests", dependencies: ["DisplayControlCore"]),
        .testTarget(name: "displayctlTests", dependencies: ["displayctl"]),
    ]
)
