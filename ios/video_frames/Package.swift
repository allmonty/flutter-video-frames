// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "video_frames",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "video-frames", targets: ["video_frames"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "video_frames",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // The plugin uses no required-reason APIs, so the privacy
                // manifest is not bundled. If that changes, describe the use in
                // PrivacyInfo.xcprivacy and uncomment:
                // .process("PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        )
    ]
)
