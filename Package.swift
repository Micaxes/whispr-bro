// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "whispr-bro",
    // iOS floor matches ios/project.yml's deploymentTarget 26.0 — the package
    // and the Xcode wrapper must agree or #available checks drift. String
    // form because `.v26` needs tools-version 6.2 and this manifest is 5.10.
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "WhisprBroCore", targets: ["WhisprBroCore"]),
        .library(name: "WhisprBroIPC", targets: ["WhisprBroIPC"]),
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
        // Single macos-arm64 slice — linked on macOS only; iOS phase i1 ships
        // no LLM (LlamaCppEngine is `#if canImport(llama)`-guarded).
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .target(
            name: "WhisprBroCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .byName(name: "llama", condition: .when(platforms: [.macOS])),
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
        // Keyboard ↔ app IPC contract + implementation (issue #13 P4). Pure
        // Foundation, ZERO dependencies — the keyboard appex links this and
        // must never pull in WhisprBroCore/FluidAudio/GRDB (~48MB jetsam
        // floor). POSIX mmap keeps it macOS-buildable so `swift test` covers
        // the whole layer off-device.
        .target(
            name: "WhisprBroIPC"
        ),
        // QuickType-parity autocorrect engine — one definition, two targets,
        // the DictationActivityAttributes pattern: the appex compiles these
        // sources through ios/project.yml's folder include of
        // Sources/WhisprBroKeyboard, and this target exists ONLY so
        // `swift test` covers the state machine off-device (the keyboard UI
        // has no unit-test target by design). Foundation-only — UIKit's
        // UITextChecker/UILexicon stay behind the injected `SpellService` —
        // never a product, never linked by the appex.
        .target(
            name: "WhisprBroAutocorrect",
            path: "Sources/WhisprBroKeyboard/AutocorrectCore"
        ),
        .testTarget(
            name: "WhisprBroCoreTests",
            dependencies: ["WhisprBroCore"]
        ),
        .testTarget(
            name: "WhisprBroIPCTests",
            dependencies: ["WhisprBroIPC"]
        ),
        .testTarget(
            name: "WhisprBroAutocorrectTests",
            dependencies: ["WhisprBroAutocorrect"]
        ),
    ]
)
