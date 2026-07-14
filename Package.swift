// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "amber-cool",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AmberCoolSMC", targets: ["AmberCoolSMC"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
    ],
    targets: [
        .target(
            name: "AmberCoolSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "fanctl",
            dependencies: ["AmberCoolSMC"]
        ),
        .executableTarget(
            name: "AmberCoolApp",
            dependencies: ["AmberCoolSMC"]
        ),
        .testTarget(
            name: "AmberCoolSMCTests",
            dependencies: ["AmberCoolSMC"]
        ),
    ]
)
