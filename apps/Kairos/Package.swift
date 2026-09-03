// swift-tools-version: 6.0
import PackageDescription

// KairosCore is deliberately a plain SwiftPM library with no Apple-framework
// dependency in its public surface, so `swift test` runs it anywhere. The one
// place a platform library is unavoidable is HMAC, and that is injected through
// `HMACProviding` rather than imported here.
let package = Package(
    name: "KairosCore",
    platforms: [.watchOS(.v11), .iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "KairosCore", targets: ["KairosCore"])
    ],
    targets: [
        .target(name: "KairosCore"),
        .testTarget(name: "KairosCoreTests", dependencies: ["KairosCore"])
    ]
)
