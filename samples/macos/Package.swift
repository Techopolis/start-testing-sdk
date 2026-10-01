// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "StartTestingMacSample", platforms: [.macOS(.v14)], dependencies: [.package(path: "../../apple")], targets: [
    .executableTarget(name: "StartTestingMacSample", dependencies: [.product(name: "StartTestingUI", package: "apple"), .product(name: "StartTestingAuth", package: "apple"), .product(name: "StartTestingChatGPT", package: "apple")], path: "Sources"),
    // Signs in with a real ChatGPT account and runs one small draft, printing each step.
    .executableTarget(name: "ChatGPTCheck", dependencies: [.product(name: "StartTestingChatGPT", package: "apple"), .product(name: "StartTestingCore", package: "apple")], path: "ChatGPTCheck")
])
