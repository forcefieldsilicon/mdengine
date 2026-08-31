// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MDEngine",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        // Products define the executables and libraries a package produces.
        .library(
            name: "LAMMPSCore",
            targets: ["LAMMPSCore"]
        ),
        .executable(
            name: "MDEngine",
            targets: ["MDEngine"]
        ),
        .executable(
            name: "mdengine-cli",
            targets: ["MDEngineCLI"]
        ),
        .executable(
            name: "mdengine-mcp",
            targets: ["MDEngineMCP"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/KarthikRIyer/swiftplot.git", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/apple/swift-numerics.git", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "LAMMPSCore",
            dependencies: []
        ),
        .executableTarget(
            name: "MDEngine",
            dependencies: [
                "LAMMPSCore",
                .product(name: "SwiftPlot", package: "swiftplot"),
                .product(name: "Numerics", package: "swift-numerics"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "MDEngineCLI",
            dependencies: ["LAMMPSCore"]
        ),
        .executableTarget(
            name: "MDEngineMCP",
            dependencies: ["LAMMPSCore"]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["LAMMPSCore"]
        ),
    ]
)
