// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YeelightStation",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AverageColor",
            targets: ["AverageColor"]
        ),
        .library(
            name: "YeelightWiFi",
            targets: ["YeelightWiFi"]
        ),
        .library(
            name: "ScreenCapture",
            targets: ["ScreenCapture"]
        ),
        .library(
            name: "YeelightSyncColorScreenCore",
            targets: ["YeelightSyncColorScreenCore"]
        ),
        .executable(
            name: "YeelightSyncColorScreen",
            targets: ["YeelightSyncColorScreen"]
        )
    ],
    targets: [
        .target(
            name: "AverageColor",
            path: "Modules/AverageColor"
        ),
        .target(
            name: "YeelightWiFi",
            path: "Modules/YeelightWiFi"
        ),
        .target(
            name: "ScreenCapture",
            path: "Modules/ScreenCapture"
        ),
        .target(
            name: "YeelightSyncColorScreenCore",
            dependencies: ["ScreenCapture", "YeelightWiFi"],
            path: "Modules/YeelightSyncColorScreenCore"
        ),
        .executableTarget(
            name: "YeelightSyncColorScreen",
            dependencies: ["ScreenCapture", "YeelightSyncColorScreenCore", "YeelightWiFi"],
            path: "YeelightSyncColorScreen"
        ),
        .testTarget(
            name: "AverageColorTests",
            dependencies: ["AverageColor"],
            path: "Tests/AverageColorTests"
        ),
        .testTarget(
            name: "ScreenCaptureTests",
            dependencies: ["ScreenCapture"],
            path: "Tests/ScreenCaptureTests"
        ),
        .testTarget(
            name: "YeelightWiFiTests",
            dependencies: ["YeelightWiFi"],
            path: "Tests/YeelightWiFiTests"
        ),
        .testTarget(
            name: "YeelightSyncColorScreenCoreTests",
            dependencies: ["YeelightSyncColorScreenCore"],
            path: "Tests/YeelightSyncColorScreenCoreTests"
        )
    ]
)
