// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeshV1",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "MeshV1", targets: ["MeshV1"]),
    ],
    targets: [
        .target(
            name: "MeshV1",
            path: "Sources/MeshV1"
        ),
        .testTarget(
            name: "MeshV1Tests",
            dependencies: ["MeshV1"],
            path: "Tests/MeshV1Tests",
            resources: [
                // Vectors are vendored under Resources/v1; keep in sync with
                // shared-vectors/v1 via tools/sync-vectors.sh.
                .copy("Resources/v1"),
            ]
        ),
    ]
)
