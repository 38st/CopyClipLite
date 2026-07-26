// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CopyClipLite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CopyClipLite", targets: ["CopyClipLite"])
    ],
    targets: [
        .executableTarget(
            name: "CopyClipLite",
            path: "Sources/CopyClipLite",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "CopyClipLiteTests",
            dependencies: ["CopyClipLite"],
            path: "Tests/CopyClipLiteTests"
        )
    ]
)
