// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StartTesting",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StartTestingCore", targets: ["StartTestingCore"]),
        .library(name: "StartTestingDiagnostics", targets: ["StartTestingDiagnostics"]),
        .library(name: "StartTestingAuth", targets: ["StartTestingAuth"]),
        .library(name: "StartTestingUI", targets: ["StartTestingUI"]),
        .library(name: "StartTestingService", targets: ["StartTestingService"]),
        .library(name: "StartTestingChatGPT", targets: ["StartTestingChatGPT"])
    ],
    targets: [
        .target(name: "StartTestingCore"),
        .target(name: "StartTestingDiagnostics", dependencies: ["StartTestingCore"]),
        .target(name: "StartTestingAuth", dependencies: ["StartTestingCore", "StartTestingDiagnostics"]),
        .target(name: "StartTestingService", dependencies: ["StartTestingCore", "StartTestingAuth"]),
        .target(name: "StartTestingChatGPT", dependencies: ["StartTestingCore"]),
        .target(name: "StartTestingUI", dependencies: ["StartTestingAuth", "StartTestingDiagnostics", "StartTestingChatGPT"]),
        .testTarget(name: "StartTestingTests", dependencies: ["StartTestingCore", "StartTestingDiagnostics", "StartTestingAuth", "StartTestingChatGPT", "StartTestingService"])
    ]
)
