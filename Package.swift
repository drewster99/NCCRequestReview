// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NCCRequestReview",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(
            name: "NCCRequestReview",
            targets: ["NCCRequestReview"]),
        .executable(
            name: "NCCRequestReview_TesterApp",
            targets: ["NCCRequestReview_TesterApp"]
        )
    ],
    targets: [
        .target(
            name: "NCCRequestReview"),
        .executableTarget(
            name: "NCCRequestReview_TesterApp",
            dependencies: [
                "NCCRequestReview"
            ]
        ),
        .testTarget(
            name: "NCCRequestReviewTests",
            dependencies: ["NCCRequestReview"]
        ),
    ]
)
