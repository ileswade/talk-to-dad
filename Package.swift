// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TalkToDad",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Kokoro text-to-speech on the Neural Engine (Core ML). Pinned.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .target(name: "TTDShared", path: "Sources/TTDShared"),
        // Runs on Dad's Mac.
        .executableTarget(
            name: "TalkToDad",
            dependencies: ["TTDShared", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/TalkToDad"
        ),
        // Runs on Iles's and Nicole's Macs.
        .executableTarget(name: "TTDFamily", dependencies: ["TTDShared"], path: "Sources/TTDFamily"),
    ],
    swiftLanguageModes: [.v5]
)
