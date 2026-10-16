// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftQuery",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SwiftQuery", targets: ["SwiftQuery"]),
        .library(name: "SwiftQuerySwiftUI", targets: ["SwiftQuerySwiftUI"]),
    ],
    targets: [
        .target(name: "SwiftQuery"),
        .target(name: "SwiftQuerySwiftUI", dependencies: ["SwiftQuery"]),
        .testTarget(name: "SwiftQueryTests", dependencies: ["SwiftQuery", "SwiftQuerySwiftUI"]),
    ]
)
