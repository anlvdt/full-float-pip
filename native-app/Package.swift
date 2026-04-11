// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FloatVideo",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "FloatVideo",
            path: "Sources"
        )
    ]
)
