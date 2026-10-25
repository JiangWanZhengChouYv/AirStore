// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StikJIT",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "StikJIT", targets: ["StikJIT"])
    ],
    targets: [
        .binaryTarget(name: "StikJIT", path: "StikJIT.xcframework")
    ]
)
