// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuotaRingCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "QuotaRingCore", targets: ["QuotaRingCore"])
    ],
    targets: [
        .target(name: "QuotaRingCore"),
        .testTarget(
            name: "QuotaRingCoreTests",
            dependencies: ["QuotaRingCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
