// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MDEngine",
    platforms: [
        .macOS(.v14),
        // iOS for the run-tracker app (GJOB-121). Only LAMMPSCore is expected to build here -- it is
        // Foundation-only, including HostedClient; MDRender is Metal/AppKit and the executables are macOS.
        .iOS(.v17),
    ],
    products: [
        // Products define the executables and libraries a package produces.
        .library(
            name: "LAMMPSCore",
            targets: ["LAMMPSCore"]
        ),
        .library(
            name: "MDRender",
            targets: ["MDRender"]
        ),
        .library(
            name: "MDEngineRunsUI",
            targets: ["MDEngineRunsUI"]
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
        .target(
            name: "MDRender",
            dependencies: ["LAMMPSCore"]
        ),
        // The iOS run tracker's screens and logic (GJOB-121/122). A library, not an app: it builds for iOS
        // AND macOS so `swift build` and `swift test` cover it before any Xcode project exists, and the app
        // target stays a thin shell around RunsRootView.
        .target(
            name: "MDEngineRunsUI",
            dependencies: ["LAMMPSCore"]
        ),
        .executableTarget(
            name: "MDEngine",
            dependencies: [
                "LAMMPSCore",
                "MDRender",
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
            dependencies: ["LAMMPSCore", "MDRender"]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["LAMMPSCore", "MDRender", "MDEngineRunsUI"]
        ),
    ]
)
