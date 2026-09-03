// swift-tools-version:6.0
import PackageDescription

// TactusCore holds every piece of metronome logic that does not touch WatchKit,
// SwiftUI or AVFoundation. Keeping it in a plain SwiftPM library means the timing
// maths can be compiled and tested on any platform with a Swift toolchain,
// including Windows, instead of only inside Xcode on a Mac.
//
// The watchOS app target in project.yml compiles the exact same files from
// Sources/TactusCore, so what is tested here is what ships.
let package = Package(
    name: "TactusCore",
    products: [
        .library(name: "TactusCore", targets: ["TactusCore"])
    ],
    targets: [
        .target(name: "TactusCore"),
        .testTarget(name: "TactusCoreTests", dependencies: ["TactusCore"])
    ]
)
