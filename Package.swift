// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "pseudocopy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "pseudocopy", targets: ["pseudocopy"])
    ],
    targets: [
        .executableTarget(
            name: "pseudocopy",
            path: "Sources/pseudocopy"
        )
    ]
)
