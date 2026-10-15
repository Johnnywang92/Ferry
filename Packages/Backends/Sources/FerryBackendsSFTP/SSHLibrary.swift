import CLibssh2
import Foundation

/// 已链接进来的 libssh2 的自述信息。
///
/// 存在两个理由：
/// 1. 诊断报告要带上 SSH 库的版本与 crypto 后端（v2.3 §诊断报告）。
/// 2. 单测靠它证明链接的是 ThirdParty/build-xcframework.sh 的产物，而不是
///    Homebrew bottle——两边版本号都是 1.11.1，光看版本分不出来，
///    必须连 crypto 后端一起看（Homebrew 那份被链到 OpenSSL 4，实测见 spike #4）。
public enum SSHLibrary {
    /// 钉在 ThirdParty/versions.env 里的 libssh2 版本：1.11.1。
    public static let expectedVersionNum: Int = 0x01_0B_01

    public static var versionNum: Int {
        Int(FerrySSH_libssh2_version_num())
    }

    /// 形如 `1.11.1_DEV`——从 git 源码构建时上游会加 `_DEV` 后缀，
    /// 所以这个串只能展示，不能用来断言版本。
    public static var versionString: String {
        FerrySSH_libssh2_version_string().map { String(cString: $0) } ?? "unknown"
    }

    public static var cryptoEngine: Engine {
        Engine(raw: FerrySSH_libssh2_crypto_engine())
    }

    public enum Engine: Sendable, Hashable {
        case none, openSSL, gcrypt, mbedtls, winCNG, os400QC3, unknown(Int32)

        init(raw: Int32) {
            switch raw {
            case 0: self = .none
            case 1: self = .openSSL
            case 2: self = .gcrypt
            case 3: self = .mbedtls
            case 4: self = .winCNG
            case 5: self = .os400QC3
            default: self = .unknown(raw)
            }
        }
    }
}
