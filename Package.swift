// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AccountGuardian",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AccountGuardian", targets: ["GuardianApp"]),
        .executable(name: "guardian-diagnostics", targets: ["GuardianDiagnostics"])
    ],
    targets: [
        .target(name: "GuardianCore"),
        .executableTarget(name: "GuardianApp", dependencies: ["GuardianCore"]),
        .executableTarget(name: "GuardianDiagnostics", dependencies: ["GuardianCore"]),
        .testTarget(name: "GuardianCoreTests", dependencies: ["GuardianCore"])
    ]
)
