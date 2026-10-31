// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MVCtoSBS",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MVCtoSBS", path: "Sources/MVCtoSBS")
    ]
)
