// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HerdrClient", targets: ["HerdrClient"]),
        .executable(name: "notchctl", targets: ["notchctl"]),
        .executable(name: "NotchApp", targets: ["NotchApp"]),
    ],
    targets: [
        // Milestone M1: headless core (socket client + models + store + classifier + actions).
        .target(
            name: "HerdrClient"
        ),
        // Milestone M1 gate: CLI harness that dogfoods the core.
        .executableTarget(
            name: "notchctl",
            dependencies: ["HerdrClient"]
        ),
        // Milestone M2: notch NSPanel UI app.
        .executableTarget(
            name: "NotchApp",
            dependencies: ["HerdrClient"],
            exclude: ["README.md"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "HerdrClientTests",
            dependencies: ["HerdrClient"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NotchAppTests",
            dependencies: ["NotchApp"]
        ),
    ]
)
