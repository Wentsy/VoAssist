// swift-tools-version:5.9
// The platform-independent core (DSP, SSML, settings, system-voice driver) as a package, so it can be unit-tested and
// listened to on the Mac (`swift test`, `swift run -c release render-samples`). The iOS app and voice extension
// (project.yml) compile the same files directly.
import PackageDescription

let package = Package(
    name: "VoAssist",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "BoostCore", targets: ["BoostCore"]),
    ],
    targets: [
        // Bill Cox's Sonic, unmodified, at the commit NVDA uses for its rate boost (see Sources/CSonic/README.md)
        .target(name: "CSonic", exclude: ["LICENSE", "README.md"]),
        .target(name: "BoostCore", dependencies: ["CSonic"]),
        .executableTarget(name: "render-samples", dependencies: ["BoostCore"]),
        .testTarget(name: "BoostCoreTests", dependencies: ["BoostCore"]),
    ]
)
