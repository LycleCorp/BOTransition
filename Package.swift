// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BOTransition",
    platforms: [.iOS(.v13)],
    products: [
        .library(
            name: "BOTransition",
            targets: ["BOTransition"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BOTransition",
            dependencies: [],
            path: "BOTransition",
            publicHeadersPath: "include"
        )
    ]
)
