// swift-tools-version: 6.0
import PackageDescription

// ProximaCore holds the parts that can be wrong without anything visibly
// breaking: service-day arithmetic, calendar exceptions, the departure
// resolver and the CSV reader the slice compiler runs on. None of them import
// an Apple framework, so `swift test` runs the whole thing on any machine.
let package = Package(
    name: "ProximaCore",
    platforms: [.watchOS(.v11), .iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ProximaCore", targets: ["ProximaCore"])
    ],
    targets: [
        .target(name: "ProximaCore"),
        .testTarget(name: "ProximaCoreTests", dependencies: ["ProximaCore"])
    ]
)
