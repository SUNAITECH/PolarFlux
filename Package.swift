// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PolarFlux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PolarFlux", targets: ["PolarFlux"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "PolarFlux",
            dependencies: [],
            path: "Sources/PolarFlux",
            resources: [
                .process("../../Resources"),
                .process("Metal/Shaders.metal")
            ]
        )
    ]
)
