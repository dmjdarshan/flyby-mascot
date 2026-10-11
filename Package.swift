// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FlyBy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FlyByCore", targets: ["FlyByCore"]),
        .executable(name: "FlyBy", targets: ["FlyByApp"]),
        .executable(name: "FlyByCoreChecks", targets: ["FlyByCoreChecks"]),
    ],
    targets: [
        .target(name: "FlyByCore"),
        .executableTarget(
            name: "FlyByApp",
            dependencies: ["FlyByCore"]
        ),
        .executableTarget(
            name: "FlyByCoreChecks",
            dependencies: ["FlyByCore"]
        ),
        .testTarget(
            name: "FlyByCoreTests",
            dependencies: ["FlyByCore"]
        ),
    ]
)
