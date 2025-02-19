// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NCCRequestReview",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "NCCRequestReview",
            targets: ["NCCRequestReview"]),
        .executable(
            name: "NCCRequestReview_TesterApp",
            targets: ["NCCRequestReview_TesterApp"]
        )
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NCCRequestReview"),
        .executableTarget(
            name: "NCCRequestReview_TesterApp",
            dependencies: [
                // Add target dependencies here
                "NCCRequestReview"
            ],
            resources: [
                // Add any resource files here
                // .process("Resources/")
            ]
        ),

    ]
)
