// swift-tools-version: 6.0
import PackageDescription

// M0b 签名走查用的最小 App 骨架：一个可执行体 + Info.plist + entitlements，
// 由 App/build-and-sign.sh 组装成 Ferry.app 并逐层签名。
//
// 它不是 M1 的正式 App target，但签名链路是真的：
// 链接的是 ThirdParty/build-xcframework.sh 的静态产物，
// 所以 Hardened Runtime 会不会拦我们的库，在这里就能测出来。
let package = Package(
    name: "FerryApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/Core"),
        .package(path: "../Packages/Backends")
    ],
    targets: [
        .executableTarget(
            name: "Ferry",
            dependencies: [
                .product(name: "FerryCore", package: "Core"),
                .product(name: "FerrySSHShim", package: "Backends"),
                .product(name: "FerryBackendsSFTP", package: "Backends"),
                .product(name: "FerryBackendsFTP", package: "Backends")
            ],
            path: "Sources/Ferry"
        )
    ]
)
