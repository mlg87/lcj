// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clusage-menubar",
    platforms: [.macOS(.v13)],   // v13 floor: SMAppService for Launch at Login
    targets: [
        .target(name: "ClusageCore"),
        .executableTarget(name: "ClusageMenubar", dependencies: ["ClusageCore"]),
        .executableTarget(name: "ClusageTests", dependencies: ["ClusageCore"]),
    ]
)
