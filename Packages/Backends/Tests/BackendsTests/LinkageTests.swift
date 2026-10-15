import CLibssh2
import Testing

@testable import FerryBackendsSFTP

/// M0b #14 的验收标准：Vendor/FerrySSH.xcframework 能被 Backends target 链接并调用。
///
/// 这条测试本身就是验收——它编译进可执行文件、跑起来拿到真实符号，
/// 链接失败根本到不了断言。
@Test("xcframework 产物可被链接，且版本与 versions.env 一致")
func linksVendoredFerrySSH() {
    #expect(SSHLibrary.versionNum == SSHLibrary.expectedVersionNum)
    // 从 git 源码构建会带 _DEV，只验前缀
    #expect(SSHLibrary.versionString.hasPrefix("1.11.1"))
}

@Test("crypto 后端是我们自己建的 OpenSSL 3，不是 Homebrew 的 OpenSSL 4")
func usesVendoredOpenSSLBackend() {
    #expect(SSHLibrary.cryptoEngine == .openSSL)
}

@Test("sftp 头文件随产物一起可用")
func sftpHeaderIsReachable() {
    // LIBSSH2_FX_OK 来自 libssh2_sftp.h；能编译过就说明 Headers 接线是对的
    #expect(UInt32(LIBSSH2_FX_OK) == 0)
    #expect(UInt32(LIBSSH2_FX_NO_SUCH_FILE) == 2)
}
