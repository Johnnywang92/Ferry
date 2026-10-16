// swift-tools-version: 6.0
import PackageDescription

// M0a 技术验证专用，独立可删。这里刻意直接调 libssh2 C API，
// 不经过 Core 协议抽象——spike 要测的就是底层库本身的行为。
// 两个例外：path 模式要用 Core 的 PathResolver 去对服务器的 realpath，
// 那是"实现 vs 事实"的对照；handshake 模式必须走 Backends 的正式实现，
// 因为它测的就是以后要发布的那条握手路径。
//
// M0b 起链的是 ThirdParty/build-xcframework.sh 的产物（锁定 commit + 静态 OpenSSL 3），
// 通过 Backends 包复用同一个 CLibssh2 模块——模块名不变，spike 代码无需改动。
// 换库之前 M0a 的结论不能直接沿用：Homebrew bottle 被链到 OpenSSL 4，
// 所以 #4（取消打断）、#7/#8（API 存在性与私钥解析）和 path oracle 都要在正式产物上重跑，
// 重跑结果记在 docs/spike/M0b-* 里。
let package = Package(
    name: "Spike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/Core"),
        .package(path: "../Packages/Backends")
    ],
    targets: [
        .executableTarget(
            name: "SpikeRunner",
            dependencies: [
                .product(name: "FerrySSHShim", package: "Backends"),
                // handshake 探针测的是正式实现，不是再抄一遍 libssh2 调用。
                .product(name: "FerryBackendsSFTP", package: "Backends"),
                .product(name: "FerryCore", package: "Core")
            ],
            path: "Sources/SpikeRunner"
        )
    ]
)
