// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FeiXunMai",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CSBC",
            path: "Sources/CSBC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "FeiXunMai",
            dependencies: ["CSBC"],
            path: "Sources/FeiXunMai"
        ),
    ]
)
