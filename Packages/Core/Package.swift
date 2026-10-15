// swift-tools-version: 6.0
import PackageDescription

// Core 零 C 依赖是硬约束：只依赖 Foundation，单测可在任意环境秒级运行。
// 见 ADR-0000 与 v2.3《架构分层与项目结构》。
let package = Package(
    name: "Core",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FerryCore", targets: ["FerryCore"])
    ],
    targets: [
        .target(name: "FerryCore", path: "Sources/FerryCore"),
        .testTarget(name: "CoreTests", dependencies: ["FerryCore"], path: "Tests/CoreTests")
    ]
)
