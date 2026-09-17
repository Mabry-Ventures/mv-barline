// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacOS27ArrangementLab",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArrangementLabCore", targets: ["ArrangementLabCore"]),
        .executable(name: "BarlineArrangementFixture", targets: ["BarlineArrangementFixture"]),
        .executable(name: "BarlineArrangementObserver", targets: ["BarlineArrangementObserver"]),
    ],
    targets: [
        .target(name: "ArrangementLabCore"),
        .executableTarget(
            name: "BarlineArrangementFixture",
            dependencies: ["ArrangementLabCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "BarlineArrangementObserver",
            dependencies: ["ArrangementLabCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "ArrangementLabCoreTests", dependencies: ["ArrangementLabCore"]),
    ],
    swiftLanguageModes: [.v6]
)
