// swift-tools-version: 6.0
import PackageDescription

// VolumenCore holds the parts that can be wrong without anything visibly
// breaking: the position model that keeps a listener's place across a pile of
// files, the ID3 chapter reader, and the transport state machine. None of them
// import an Apple framework, so `swift test` runs the whole thing on any
// machine.
let package = Package(
    name: "VolumenCore",
    platforms: [.watchOS(.v11), .iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "VolumenCore", targets: ["VolumenCore"])
    ],
    targets: [
        .target(name: "VolumenCore"),
        .testTarget(name: "VolumenCoreTests", dependencies: ["VolumenCore"])
    ]
)
