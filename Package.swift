// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Claudeman",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(path: "Packages/ClaudemanKit"),
    ],
    targets: [
        .executableTarget(
            name: "Claudeman",
            dependencies: ["SwiftTerm", "ClaudemanKit"],
            path: "Sources/Claudeman"
        ),
    ]
)
