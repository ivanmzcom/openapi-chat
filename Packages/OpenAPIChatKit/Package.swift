// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenAPIChatKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "OpenAPIChatKit", targets: ["OpenAPIChatKit"]),
        .executable(name: "openapi-chat", targets: ["openapi-chat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "OpenAPIChatKit", dependencies: ["Yams"]),
        .executableTarget(name: "openapi-chat", dependencies: ["OpenAPIChatKit"]),
        .testTarget(
            name: "OpenAPIChatKitTests",
            dependencies: ["OpenAPIChatKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
