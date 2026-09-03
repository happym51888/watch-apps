// swift-tools-version:6.0
import PackageDescription

// AwqatCore is the offline prayer-time engine: Meeus solar astronomy, the published
// angles for each calculation convention, the high-latitude fallbacks, and the
// Qibla bearing. No network, no Apple frameworks, no Calendar-and-TimeZone
// guesswork — so it compiles and runs its test suite on any Swift toolchain,
// Windows included, and the watchOS app in project.yml compiles the same files.
let package = Package(
    name: "AwqatCore",
    products: [
        .library(name: "AwqatCore", targets: ["AwqatCore"])
    ],
    targets: [
        .target(name: "AwqatCore"),
        .testTarget(name: "AwqatCoreTests", dependencies: ["AwqatCore"])
    ]
)
