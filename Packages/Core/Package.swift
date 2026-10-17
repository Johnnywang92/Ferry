// swift-tools-version: 6.0
import PackageDescription

// Core 零 C 依赖是硬约束：只依赖 Foundation，单测可在任意环境秒级运行。
// 见 ADR-0000 与 v2.3《架构分层与项目结构》.
//
// FerryContracts 是唯一的例外，理由具体：契约套件必须在**两个 package 的测试
// target 里**跑同一份代码（CoreTests 跑内存 fake，BackendsTests 跑 SFTP），
// 而 SwiftPM 里一个测试 target 的代码没法被另一个 package 引用。
// 做成 product 之后两边都 import 它，"同一套用例"就是类型层面的事实而不是约定。
// 它不参与 App 的链接，只是测试基础设施——所以不进默认依赖。
let package = Package(
    name: "Core",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FerryCore", targets: ["FerryCore"]),
        .library(name: "FerryContracts", targets: ["FerryContracts"])
    ],
    targets: [
        .target(name: "FerryCore", path: "Sources/FerryCore"),
        .target(name: "FerryContracts", dependencies: ["FerryCore"], path: "Sources/FerryContracts"),
        .testTarget(
            name: "CoreTests",
            dependencies: ["FerryCore", "FerryContracts"],
            path: "Tests/CoreTests"
        ),
        // 契约套件自己的测试：只验内存 fake 那一边跑通。真机那一边在
        // BackendsTests 里（那里才有 libssh2），两边 import 的是同一个模块。
        .testTarget(
            name: "ContractsTests",
            dependencies: ["FerryCore", "FerryContracts"],
            path: "Tests/ContractsTests"
        )
    ]
)
