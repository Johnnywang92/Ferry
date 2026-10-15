// swift-tools-version: 6.0
import Foundation
import PackageDescription

// M0a 技术验证专用，独立可删。这里刻意直接调 libssh2 C API，
// 不经过 Core 协议抽象——spike 要测的就是底层库本身的行为。
//
// 链接的是 Homebrew 开发版 libssh2（Sources/CLibssh2/shim.h 里是绝对 include 路径，
// libssh2.h 与 libssh2_sftp.h 都要包，后者不在前者之内），
// 且它被 bottle 链到了 OpenSSL 4，不是最终要用的 OpenSSL 3.x。
// 因此 M0b 换成锁定 commit + 静态 OpenSSL 3.x 的 xcframework 后，
// spike #4（取消打断）与 #7/#8（API 存在性、私钥解析）必须用正式产物重跑。
let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"

let package = Package(
    name: "Spike",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CLibssh2", path: "Sources/CLibssh2"),
        .executableTarget(
            name: "SpikeRunner",
            dependencies: ["CLibssh2"],
            path: "Sources/SpikeRunner",
            linkerSettings: [
                .unsafeFlags(["-L\(brewPrefix)/lib"]),
                .linkedLibrary("ssh2")
            ]
        )
    ]
)
