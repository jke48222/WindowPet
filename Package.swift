// swift-tools-version: 5.9
// Swift 5 language mode on purpose for the weekend spike: AppKit + strict
// concurrency (Swift 6 mode) is a migration project of its own. Revisit at S3.
import PackageDescription

let package = Package(
    name: "WindowPet",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure math + policy. No AppKit import, fully unit-testable headless.
        .target(name: "WindowPetCore", path: "Sources/WindowPetCore"),
        // The app.
        .executableTarget(
            name: "WindowPet",
            dependencies: ["WindowPetCore"],
            path: "Sources/WindowPet",
            resources: [.process("Resources")]
        ),
        // One-shot sprite generator; writes Resources/pet.png. Art is a build
        // input, not runtime drawing — swap the PNG for commissioned art later.
        .executableTarget(name: "PetGen", path: "Sources/PetGen"),
        .testTarget(
            name: "WindowPetCoreTests",
            dependencies: ["WindowPetCore"],
            path: "Tests/WindowPetCoreTests"
        ),
    ]
)
