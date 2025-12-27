// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumiSync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LumiSync", targets: ["LumiSync"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "LumiSync",
            dependencies: [],
            path: "Sources/LumiSync",
            resources: [
                .copy("../../Resources/Info.plist"),
                .copy("../../Resources/LumiSync.icns")
            ]
        )
    ]
)
