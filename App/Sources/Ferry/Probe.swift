import CLibssh2
import Darwin
import FerryBackendsSFTP
import Foundation
import Security

/// M0b 签名走查探针：保留给 build-and-sign.sh 与无头环境验证签名与 Hardened Runtime。
@MainActor
public func runSigningProbe() {
    var checks: [(name: String, verdict: String, detail: String)] = []

    func record(_ name: String, _ verdict: String, _ detail: String) {
        checks.append((name, verdict, detail))
        print(String(format: "  [%@] %@ — %@", verdict, name, detail))
    }

    let args = CommandLine.arguments
    let skipKeychain = args.contains("--skip-keychain")

    let stampPath = ProcessInfo.processInfo.environment["FERRY_STAMP"] ?? "/tmp/ferry-launch-stamp.txt"
    let stamp = "pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "nil") "
        + "path=\(Bundle.main.bundlePath) when=\(Int(Date().timeIntervalSince1970))\n"
    try? stamp.write(toFile: stampPath, atomically: true, encoding: .utf8)

    print("== Ferry 签名走查探针 ==")
    if let bundle = Bundle.main.bundleIdentifier {
        print("包标识：\(bundle)（临时值，M2 接 Keychain 前换成正式反域前缀，见 ADR-0000 §8 V5）")
    } else {
        print("包标识：nil —— 说明不是从 .app 里跑的，Keychain 那项测不出真实行为")
    }
    print("可执行体：CommandLine.arguments[0] = \(args[0])")
    print("主二进制：\(Bundle.main.executablePath ?? "?")")

    // ——— 1. 静态库在签名产物里可用
    let version = SSHLibrary.versionString
    let engine = SSHLibrary.cryptoEngine
    let versionNumOk = SSHLibrary.versionNum == SSHLibrary.expectedVersionNum
    record("静态 libssh2 可调用",
           (versionNumOk && engine == .openSSL) ? "PASS" : "FAIL",
           "版本串 \(version)、NUM \(SSHLibrary.versionNum) 期望 \(SSHLibrary.expectedVersionNum)、后端 \(engine)")

    // ——— 2. dlopen 系统库
    func tryDlopen(_ path: String) -> String? {
        guard let h = dlopen(path, RTLD_NOW) else {
            return String(cString: dlerror())
        }
        dlclose(h)
        return nil
    }
    do {
        let sys = "/usr/lib/libz.1.dylib"
        if let err = tryDlopen(sys) {
            record("dlopen 系统库", "FAIL", "\(sys) 被拒：\(err)")
        } else {
            record("dlopen 系统库", "PASS", "\(sys) 加载成功（Apple 签名，library validation 放行）")
        }
    }

    // ——— 3. dlopen 第三方 dylib
    do {
        let extra = ProcessInfo.processInfo.environment["FERRY_DLOPEN_PATH"]
        for thirdParty in ["/opt/homebrew/lib/libssh2.1.dylib", extra].compactMap({ $0 }) {
            if !FileManager.default.fileExists(atPath: thirdParty) {
                record("dlopen 第三方 dylib", "SKIP", "\(thirdParty) 不存在，测不了")
            } else if let err = tryDlopen(thirdParty) {
                record("dlopen 非系统 dylib \(thirdParty)", "PASS",
                       "按预期被拒：\(err.split(separator: "\n").first ?? "")")
            } else {
                record("dlopen 非系统 dylib \(thirdParty)", "NOTE",
                       "加载成功——这一层没在拦（走查文档里要说清是哪种情况）")
            }
        }
    }

    // ——— 4. 出网
    do {
        let host = ProcessInfo.processInfo.environment["SPIKE_HOST"] ?? "127.0.0.1"
        let port = Int32(ProcessInfo.processInfo.environment["SPIKE_PORT"] ?? "") ?? 2202
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let rc = withUnsafeBytes(of: &addr) { body in
            body.baseAddress!.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 {
            var banner = [UInt8](repeating: 0, count: 64)
            let n = read(fd, &banner, banner.count)
            let text = n > 0 ? String(decoding: banner[0..<n], as: UTF8.self) : "(没读到 banner)"
            record("出网 + 读到 SSH banner", n > 0 ? "PASS" : "NOTE", "\(host):\(port) 连通，banner：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            record("出网", "NOTE", "connect \(host):\(port) rc=\(rc) errno=\(errno)（无后台容器时作为 NOTE）")
        }
        close(fd)
    }

    // ——— 5. Keychain
    func keychainProbe(label: String, dataProtection: Bool) {
        let service = ProcessInfo.processInfo.environment["FERRY_KC_SERVICE"] ?? "local.ferry.signingprobe"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "probe"
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue }

        let readStatus = SecItemCopyMatching(query as CFDictionary, nil)
        var writeStatus = OSStatus(-1)
        if readStatus == errSecSuccess || readStatus == errSecItemNotFound {
            var add = query
            let payload = "written-at-\(Int(Date().timeIntervalSince1970))".data(using: .utf8)!
            add[kSecValueData as String] = payload
            if dataProtection { add[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue }
            writeStatus = SecItemAdd(add as CFDictionary, nil)
            if writeStatus == errSecDuplicateItem {
                var update: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                             kSecAttrService as String: service,
                                             kSecAttrAccount as String: "probe"]
                if dataProtection { update[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue }
                writeStatus = SecItemUpdate(update as CFDictionary,
                                            [kSecValueData as String: payload] as CFDictionary)
            }
        }
        let afterRead = SecItemCopyMatching(query as CFDictionary, nil)
        let text: String
        switch readStatus {
        case errSecSuccess: text = "首次读=已存在"
        case errSecItemNotFound: text = "首次读=没有条目"
        default: text = "首次读=err \(readStatus)"
        }
        let writeText: String
        switch writeStatus {
        case errSecSuccess: writeText = "写=ok"
        case errSecItemNotFound: writeText = "写=跳过（读已失败）"
        default: writeText = "写=err \(writeStatus)"
        }
        let afterText: String
        switch afterRead {
        case errSecSuccess: afterText = "复读=ok"
        case errSecItemNotFound:
            afterText = writeStatus == errSecSuccess
                ? "复读=没有条目（写进去又读不到，多半是身份绑定问题）"
                : "复读=没有条目（写本身就没成功，这里只是印证没落盘）"
        default: afterText = "复读=err \(afterRead)"
        }
        let ok = afterRead == errSecSuccess
        record("Keychain \(label)", ok ? "PASS" : "FAIL", "\(text)，\(writeText)，\(afterText)")
    }

    if skipKeychain {
        print("  Keychain 探针：--skip-keychain 跳过")
    } else {
        SecKeychainSetUserInteractionAllowed(false)
        keychainProbe(label: "登录钥匙串", dataProtection: false)
        keychainProbe(label: "data-protection 钥匙串", dataProtection: true)
    }

    let failed = checks.filter { $0.verdict == "FAIL" }
    print("汇总：\(checks.count) 项，FAIL \(failed.count)")
    for f in failed { print("  FAIL：\(f.name) — \(f.detail)") }
    exit(failed.isEmpty ? 0 : 1)
}
