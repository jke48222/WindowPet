// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode: the compiler now enforces the actor isolation this
// app always relied on informally. The UI classes (AppDelegate, CommandBar,
// AgentSession, TestRig, the engine and stage) are @MainActor, so a second
// agent turn or a stray timer callback cannot race the conversation state.
let package = Package(
    name: "WindowPet",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure math + policy. No AppKit import, fully unit-testable headless.
        .target(
            name: "WindowPetCore",
            path: "Sources/WindowPetCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The app.
        .executableTarget(
            name: "WindowPet",
            dependencies: ["WindowPetCore"],
            path: "Sources/WindowPet",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // One-shot sprite generator; writes the skin frames into Resources.
        // Art is a build input, not runtime drawing.
        .executableTarget(
            name: "PetGen",
            path: "Sources/PetGen",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WindowPetCoreTests",
            dependencies: ["WindowPetCore"],
            path: "Tests/WindowPetCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
