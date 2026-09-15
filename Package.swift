// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cool42",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CSMC", path: "Sources/CSMC"),
        .executableTarget(
            name: "cool42",
            dependencies: ["CSMC"],
            path: "Sources/cool42",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
