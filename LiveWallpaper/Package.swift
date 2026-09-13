// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "LiveWallpaperCore",
    targets: [
        .target(
            name: "PlaybackCoordinator",
            path: "Sources",
            sources: ["PlaybackCoordinator.swift", "PowerPausePolicy.swift"]
        ),
        .testTarget(
            name: "PlaybackCoordinatorTests",
            dependencies: ["PlaybackCoordinator"],
            path: "Tests"
        )
    ]
)
