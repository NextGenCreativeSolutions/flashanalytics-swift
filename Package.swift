// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FlashAnalytics",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "FlashAnalytics",
            targets: ["FlashAnalytics"]
        ),
    ],
    targets: [
        .target(
            name: "FlashAnalytics"
        ),
        .testTarget(
            name: "FlashAnalyticsTests",
            dependencies: ["FlashAnalytics"]
        ),
    ]
)
