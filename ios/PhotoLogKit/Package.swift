// swift-tools-version: 5.9
import PackageDescription

// The platform-independent half of the iOS app, split out as its own package.
//
// Not a stylistic choice: this is the only part of the iOS port that can be *verified* without a
// Mac in the loop, because `swift test` runs it on a macOS CI runner with no simulator, no
// signing, and no Xcode project. The app target depends on it; the tests cover it; the ZIP
// writer and the export naming are therefore checked rather than assumed.
let package = Package(
    name: "PhotoLogKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PhotoLogKit", targets: ["PhotoLogKit"]),
    ],
    targets: [
        .target(name: "PhotoLogKit"),
        .testTarget(name: "PhotoLogKitTests", dependencies: ["PhotoLogKit"]),
    ]
)
