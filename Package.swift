// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FloatingAI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FloatingAI", targets: ["FloatingAI"]),
        .executable(name: "FloatingAIFileTool", targets: ["FloatingAIFileTool"]),
        .executable(name: "FloatingAIChecks", targets: ["FloatingAIChecks"])
    ],
    targets: [
        .target(name: "FloatingAICore"),
        .executableTarget(name: "FloatingAI", dependencies: ["FloatingAICore"]),
        .executableTarget(name: "FloatingAIFileTool", dependencies: ["FloatingAICore"]),
        .target(name: "FloatingAICheckSupport", dependencies: ["FloatingAICore"], path: "Checks/Support"),
        .executableTarget(name: "FloatingAIChecks", dependencies: ["FloatingAICore", "FloatingAICheckSupport"], path: "Checks/Runner"),
        .testTarget(name: "FloatingAICoreTests", dependencies: ["FloatingAICore", "FloatingAICheckSupport"])
    ]
)
