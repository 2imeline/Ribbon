// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ribbon",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "RibbonCore"),
        .executableTarget(name: "Ribbon", dependencies: ["RibbonCore"]),
        .testTarget(name: "RibbonCoreTests", dependencies: ["RibbonCore"]),
    ],
    swiftLanguageModes: [.v5]
)
