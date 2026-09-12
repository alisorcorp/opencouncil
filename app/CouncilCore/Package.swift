// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CouncilCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CouncilCore", targets: ["CouncilCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5"),
    ],
    targets: [
        .target(
            name: "CouncilCore",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
        ),
        .testTarget(
            name: "CouncilCoreTests",
            dependencies: ["CouncilCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
