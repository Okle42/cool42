// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cool42",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSMC", path: "Sources/CSMC"),
        .target(name: "Cool42Core", dependencies: ["CSMC"], path: "Sources/Cool42Core",
                linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "cool42", dependencies: ["Cool42Core"], path: "Sources/cool42"),
        .executableTarget(name: "cool42-panel", dependencies: ["Cool42Core"], path: "Sources/cool42-panel"),
        .testTarget(name: "Cool42CoreTests", dependencies: ["Cool42Core"], path: "Tests/Cool42CoreTests"),
    ]
)
