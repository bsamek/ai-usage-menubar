// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AIUsageMenuBar", targets: ["AIUsageMenuBar"]),
        .executable(name: "AIUsageChecks", targets: ["AIUsageChecks"]),
    ],
    targets: [
        .target(name: "AIUsageCore"),
        .executableTarget(name: "AIUsageMenuBar", dependencies: ["AIUsageCore"]),
        // A standalone runner also works with Command Line Tools, without Xcode/XCTest.
        .executableTarget(name: "AIUsageChecks", dependencies: ["AIUsageCore"], path: "Tests/AIUsageChecks"),
    ]
)
