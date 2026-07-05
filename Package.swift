// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "whispr-bro",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisprBroCore", targets: ["WhisprBroCore"]),
        .executable(name: "WhisprBro", targets: ["WhisprBro"]),
        .executable(name: "whispr-bench", targets: ["whispr-bench"]),
    ],
    dependencies: [
        // Pinned exactly: model-loading behavior and TdtConfig defaults are
        // version-sensitive (v2 blankId vs v3) — bump deliberately.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        // Prebuilt by scripts/build-llama-xcframework.sh (pinned llama.cpp tag,
        // Metal embedded). Gitignored; run that script once before building.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .target(
            name: "WhisprBroCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "llama",
            ]
        ),
        .executableTarget(
            name: "WhisprBro",
            dependencies: ["WhisprBroCore"]
        ),
        .executableTarget(
            name: "whispr-bench",
            dependencies: ["WhisprBroCore"]
        ),
        .testTarget(
            name: "WhisprBroCoreTests",
            dependencies: ["WhisprBroCore"]
        ),
    ]
)
