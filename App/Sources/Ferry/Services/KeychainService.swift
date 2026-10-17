import Foundation
import Security

/// 登录钥匙串凭据管理服务（ADR-0000 §8 V3 / §13 M2-D1）。
///
/// - 统一使用 macOS 登录钥匙串（不传 `kSecUseDataProtectionKeychain`，避免 ad-hoc 签名下 `-34018`）；
/// - 服务命名空间锁定为 `dev.ferry.app`（支持经环境变量 `FERRY_KC_SERVICE` 注入测试隔离命名空间）；
/// - 密码与私钥口令绝不落入 `sites.json`，仅在用户勾选"将密码保存到钥匙串"时按站点 UUID 存入本服务。
public struct KeychainService: Sendable {
    public enum SecretKind: String, Sendable {
        case password = "password"
        case passphrase = "passphrase"
    }

    public static let shared = KeychainService()

    public let serviceName: String

    public init(serviceName: String? = nil) {
        if let serviceName {
            self.serviceName = serviceName
        } else {
            self.serviceName = ProcessInfo.processInfo.environment["FERRY_KC_SERVICE"] ?? "dev.ferry.app"
        }
    }

    private func accountKey(for siteID: UUID, kind: SecretKind) -> String {
        "\(siteID.uuidString).\(kind.rawValue)"
    }

    @discardableResult
    public func saveSecret(_ secret: String, for siteID: UUID, kind: SecretKind) -> Bool {
        guard !secret.isEmpty else {
            deleteSecret(for: siteID, kind: kind)
            return true
        }
        guard let payload = secret.data(using: .utf8) else { return false }
        let account = accountKey(for: siteID, kind: kind)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: payload
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            return updateStatus == errSecSuccess
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = payload
            addQuery[kSecAttrLabel as String] = "Ferry (\(kind.rawValue))"
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
    }

    public func loadSecret(for siteID: UUID, kind: SecretKind) -> String? {
        let account = accountKey(for: siteID, kind: kind)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    public func deleteSecret(for siteID: UUID, kind: SecretKind) {
        let account = accountKey(for: siteID, kind: kind)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func deleteAllSecrets(for siteID: UUID) {
        deleteSecret(for: siteID, kind: .password)
        deleteSecret(for: siteID, kind: .passphrase)
    }
}
