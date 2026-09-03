// swift-tools-version: 6.0
import PackageDescription

// VerbaCore holds the parts that can be wrong without anything visibly
// breaking: the delivery queue, the retry schedule, the chunk plan and the
// transcript stitcher. None of them import an Apple framework, so `swift test`
// runs the whole thing on any machine.
let package = Package(
    name: "VerbaCore",
    platforms: [.watchOS(.v11), .iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "VerbaCore", targets: ["VerbaCore"])
    ],
    targets: [
        .target(name: "VerbaCore"),
        .testTarget(name: "VerbaCoreTests", dependencies: ["VerbaCore"])
    ]
)
