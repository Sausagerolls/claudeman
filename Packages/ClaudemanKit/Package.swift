// swift-tools-version:5.10
import PackageDescription

/// Wire types shared by the Claudeman Mac app and the Claudeman Remote iOS app.
let package = Package(
    name: "ClaudemanKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClaudemanKit", targets: ["ClaudemanKit"]),
    ],
    targets: [
        .target(name: "ClaudemanKit"),
    ]
)
