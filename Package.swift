// swift-tools-version: 6.2
import PackageDescription

// Three products, deliberately split:
// - MulliganText and MulliganDictionary are Foundation-only and platform-neutral, so every
//   line of text processing is unit-testable without a window, a microphone, or macOS 26.
// - Mulligan is the app: AppKit, SwiftUI, Speech, and the OS-level machinery.
let package = Package(
    name: "Mulligan",
    platforms: [.macOS(.v26)],
    dependencies: [
        // NVIDIA Parakeet TDT as CoreML, behind the engine seam as an experimental second engine
        // for side-by-side accuracy testing against Apple's SpeechAnalyzer (SPEC 6.6a).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.7", traits: []),
    ],
    targets: [
        .target(
            name: "MulliganText",
            path: "Sources/MulliganText",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MulliganDictionary",
            path: "Sources/MulliganDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Mulligan",
            dependencies: [
                "MulliganText",
                "MulliganDictionary",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Mulligan",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MulliganTextTests",
            dependencies: ["MulliganText"],
            path: "Tests/MulliganTextTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MulliganAppTests",
            dependencies: ["Mulligan"],
            path: "Tests/MulliganAppTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MulliganDictionaryTests",
            dependencies: ["MulliganDictionary"],
            path: "Tests/MulliganDictionaryTests",
            resources: [.copy("vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
