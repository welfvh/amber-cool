// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "amber-temp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AmberTempSMC", targets: ["AmberTempSMC"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
    ],
    targets: [
        .target(
            name: "AmberTempSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "fanctl",
            dependencies: ["AmberTempSMC"]
        ),
    ]
)
