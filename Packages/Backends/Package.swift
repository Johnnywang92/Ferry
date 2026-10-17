// swift-tools-version: 6.0
import Foundation
import PackageDescription

// libssh2 + OpenSSL 只出现在这一个 package 里，Core 保持零 C 依赖（ADR-0000）。
//
// 产物由 ThirdParty/build-xcframework.sh 从钉死 commit 建出来：
// 静态、arm64 + x86_64、OpenSSL 3 后端。不用 Homebrew——bottle 是动态库、
// 版本随 brew update 漂，而且实测被链到 OpenSSL 4。
//
// 产物必须放在包内的 Vendor/（已 gitignore）：SwiftPM 拒绝任何越出 package root
// 的 binaryTarget 路径或 header search path，放仓库根 Vendor/ 实测报
// "header search path should not be outside the package root"。
//
// 头文件要显式给搜索路径：SwiftPM 不像 Xcode 工程会自动把 binaryTarget 的
// Headers 传给依赖它的 C target。切片目录名随架构组合变
// （macos-arm64 / macos-arm64_x86_64），所以扫出来而不是写死。
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let frameworkPath = packageRoot.appendingPathComponent("Vendor/FerrySSH.xcframework").path

let slice: String = (try? FileManager.default.contentsOfDirectory(atPath: frameworkPath))
    .map { entries in
        entries.sorted().first {
            FileManager.default.fileExists(atPath: "\(frameworkPath)/\($0)/Headers")
        } ?? ""
    } ?? ""

guard FileManager.default.fileExists(atPath: frameworkPath), !slice.isEmpty else {
    // 不能静默出一个链接不过的 package——这句话比 SwiftPM 的报错有用
    fputs("缺 Packages/Backends/Vendor/FerrySSH.xcframework（或它里面没有带头文件的切片），先跑 ThirdParty/build-xcframework.sh\n", stderr)
    exit(70)
}

let package = Package(
    name: "Backends",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FerryBackendsSFTP", targets: ["FerryBackendsSFTP"]),
        // spike 期要在"临时链 Homebrew"和"链正式产物"之间来回切，
        // 所以把 C 壳单独做成产品，模块名两边都叫 CLibssh2。
        .library(name: "FerrySSHShim", targets: ["CLibssh2"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .binaryTarget(name: "FerrySSH", path: "Vendor/FerrySSH.xcframework"),
        .target(
            name: "CLibssh2",
            dependencies: ["FerrySSH"],
            cSettings: [
                // 相对 target 源码目录 Sources/CLibssh2 上溯两级到包根
                .headerSearchPath("../../Vendor/FerrySSH.xcframework/\(slice)/Headers")
            ]
        ),
        .target(
            name: "FerryBackendsSFTP",
            dependencies: [
                "CLibssh2",
                .product(name: "FerryCore", package: "Core")
            ]
        ),
        .testTarget(
            name: "BackendsTests",
            dependencies: [
                "FerryBackendsSFTP",
                "CLibssh2",
                // 契约套件本身：它住在 Core 那个 package 里，两边 import 的是同一个
                // 模块，所以"同一套用例跑两个后端"是类型层面的事实（M1' 出口标准）。
                // 少了这一行，本目录那份 SFTPContractTests 就是在跑一份抄来的代码，
                // 抽象一旦破掉没人会发现——那正是契约测试要防的事。
                .product(name: "FerryContracts", package: "Core")
            ]
        )
    ]
)
