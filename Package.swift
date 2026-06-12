// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-yeelight-wifi",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "YeelightWiFi", targets: ["YeelightWiFi"]),
        .executable(name: "Example", targets: ["Example"]),
        .executable(name: "TestOff", targets: ["TestOff"])
    ],
    targets: [
        .target(
            name: "YeelightWiFi",
            path: "Sources/YeelightWiFi"
        ),
        .executableTarget(
            name: "Example",
            dependencies: ["YeelightWiFi"],
            path: "Examples"
        ),
        .executableTarget(
            name: "TestOff",
            dependencies: ["YeelightWiFi"],
            path: "TestOff"
        )
    ]
)
