// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CGRBAR",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CGRBAR",
            path: "Sources/CGRBAR"
        ),
        .testTarget(
            name: "CGRBARTests",
            dependencies: ["CGRBAR"],
            path: "Tests/CGRBARTests"
        ),
    ]
)
