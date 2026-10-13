// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
//
// PairVox: talk to Claude Code like a pair-programming partner.
//
// Layout
//   PairVoxCore   – platform-independent engine: Claude Code stream-json protocol,
//                   session backends (subscription / API key), speech pipeline,
//                   permission policy, voice commands, conversation engine.
//                   Builds and tests on macOS and Linux.
//   PairVoxCLI    – `pairvox-cli`, a terminal front-end (Phase 0 spike harness).
//                   Builds on macOS and Linux.
//   PairVoxVoice  – macOS audio: AVAudioEngine voice-processing I/O, VAD wiring,
//                   WhisperKit + Apple speech recognition, Kokoro + system TTS.
//   PairVoxApp    – the macOS SwiftUI app.
//
// The macOS-only targets and their dependencies are declared only when the
// manifest is evaluated on macOS, so Linux CI can build and test the core.

import PackageDescription

let packageRoot = String(#filePath.dropLast("/Package.swift".count))

var products: [Product] = [
    .library(name: "PairVoxCore", targets: ["PairVoxCore"]),
    .executable(name: "pairvox-cli", targets: ["PairVoxCLI"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(
        name: "PairVoxCore",
        path: "Sources/PairVoxCore"
    ),
    .executableTarget(
        name: "PairVoxCLI",
        dependencies: ["PairVoxCore"],
        path: "Sources/PairVoxCLI"
    ),
    .testTarget(
        name: "PairVoxCoreTests",
        dependencies: ["PairVoxCore"],
        path: "Tests/PairVoxCoreTests",
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
dependencies += [
    // Speech-to-text (MIT)
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
    // Kokoro text-to-speech for Apple platforms (MIT; MisakiSwift G2P is Apache-2.0, no espeak-ng)
    .package(url: "https://github.com/mlalma/kokoro-ios.git", from: "1.0.9"),
    // MLX array types used to hold Kokoro voice styles (MIT)
    .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.29.1"),
    // .npz voice-file reader (Apache-2.0)
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", from: "0.0.6"),
]

products += [
    .library(name: "PairVoxVoice", targets: ["PairVoxVoice"]),
    // Dev convenience (`swift run pairvox-app`); the distributable app is built from project.yml.
    .executable(name: "pairvox-app", targets: ["PairVoxApp"]),
]

targets += [
    .target(
        name: "PairVoxVoice",
        dependencies: [
            "PairVoxCore",
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "KokoroSwift", package: "kokoro-ios"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
        ],
        path: "Sources/PairVoxVoice",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "PairVoxApp",
        dependencies: ["PairVoxCore", "PairVoxVoice"],
        path: "Sources/PairVoxApp",
        exclude: ["Info.plist", "PairVox.entitlements"],
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            // Embed Info.plist in the binary so microphone / speech-recognition
            // usage descriptions work even when run straight from Xcode or `swift run`.
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "\(packageRoot)/Sources/PairVoxApp/Info.plist",
            ]),
        ]
    ),
]
#endif

let package = Package(
    name: "PairVox",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
