// swift-tools-version: 6.0
// Local fork of FluidAudio with @unchecked Sendable fix for AsrManager.
// Remove this local override once the fix is merged upstream:
// https://github.com/FluidInference/FluidAudio
import PackageDescription

let package = Package(
    name: "FluidAudio",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "FluidAudio",
            targets: ["FluidAudio"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6")
    ],
    targets: [
        .target(
            name: "FluidAudio",
            dependencies: [
                "FastClusterWrapper",
                "MachTaskSelfWrapper",
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/FluidAudio",
            exclude: [
                "Frameworks"
            ]
        ),
        .target(
            name: "FastClusterWrapper",
            path: "Sources/FastClusterWrapper",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MachTaskSelfWrapper",
            path: "Sources/MachTaskSelfWrapper",
            publicHeadersPath: "include"
        ),
    ]
)
