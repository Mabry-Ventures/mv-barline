// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacOS27ArrangementLab",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArrangementLabCore", targets: ["ArrangementLabCore"]),
        .library(name: "SyntheticDragProbe", targets: ["SyntheticDragProbe"]),
        .executable(name: "BarlineArrangementFixture", targets: ["BarlineArrangementFixture"]),
        .executable(name: "BarlineArrangementObserver", targets: ["BarlineArrangementObserver"]),
    ],
    targets: [
        .target(name: "ArrangementLabCore"),
        .target(
            name: "SyntheticDragProbe",
            dependencies: ["ArrangementLabCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "BarlineArrangementFixture",
            dependencies: ["ArrangementLabCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "BarlineArrangementObserver",
            dependencies: ["ArrangementLabCore", "SyntheticDragProbe"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "ArrangementLabCoreTests", dependencies: ["ArrangementLabCore"]),
    ],
    swiftLanguageModes: [.v6]
)
