// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kouch",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Kouch", targets: ["Kouch"]),
        .library(name: "KouchSwiftUI", targets: ["KouchSwiftUI"]),
    ],
    targets: [
        .target(name: "Kouch"),
        .target(name: "KouchSwiftUI", dependencies: ["Kouch"]),
        .testTarget(name: "KouchTests", dependencies: ["Kouch", "KouchSwiftUI"]),
    ]
)
