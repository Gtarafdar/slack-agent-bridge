// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlackAgentBridge",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SlackAgentBridge",
            path: "Sources/SlackAgentBridge"
        )
    ]
)
