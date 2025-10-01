// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "DepthPrediction",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "DepthRunner", targets: ["DepthRunner"])
    ],
    targets: [
        .executableTarget(
            name: "DepthRunner",
            path: "Sources/DepthRunner"
        )
    ]
)
