// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "DrawPlay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "drawplayd", targets: ["drawplayd"]),
        .executable(name: "DrawPlay", targets: ["DrawPlayApp"]),
    ],
    targets: [
        .target(name: "VDShim", path: "Sources/VDShim", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "DrawPlayCore", dependencies: ["VDShim"], path: "Sources/DrawPlayCore"),
        .executableTarget(name: "drawplayd", dependencies: ["DrawPlayCore"], path: "Sources/drawplayd"),
        .executableTarget(name: "DrawPlayApp", dependencies: ["DrawPlayCore"], path: "Sources/DrawPlayApp"),
    ]
)
