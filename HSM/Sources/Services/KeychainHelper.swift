import Foundation
import Security
import os.log

enum KeychainHelper {
    // Stable service identifier - never change this or existing items become unreachable.
    private static let service = "net.mohome.hsm"
    private static let log = Logger(subsystem: "net.mohome.hsm", category: "Keychain")

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)

        // Write/update the synchronizable (iCloud Keychain) item.
        // kSecAttrSynchronizable requires a non-ThisDeviceOnly accessibility class.
        let syncSearch: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!
        ]
        var status = SecItemUpdate(syncSearch as CFDictionary,
                                   [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
        if status == errSecItemNotFound {
            var add = syncSearch
            add[kSecValueData as String]      = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess {
                log.error("SecItemAdd failed for account=\(account, privacy: .public) status=\(status)")
            }
        } else if status != errSecSuccess {
            log.error("SecItemUpdate failed for account=\(account, privacy: .public) status=\(status)")
        }

        // Clean up any legacy non-synchronizable item with the same key.
        let localSearch: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]
        SecItemDelete(localSearch as CFDictionary)
    }

    static func load(account: String) -> String? {
        // Try synchronizable item first (current format).
        let syncQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecReturnData as String:         true
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(syncQuery as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("SecItemCopyMatching (sync) failed for account=\(account, privacy: .public) status=\(status)")
        }

        // Fall back to non-synchronizable item (migration path from older builds).
        // If found, re-save so it becomes synchronizable going forward.
        let localQuery: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecReturnData as String:         true
        ]
        result = nil
        status = SecItemCopyMatching(localQuery as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            save(value, account: account)   // Migrate: write sync, delete local.
            return value
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("SecItemCopyMatching (local) failed for account=\(account, privacy: .public) status=\(status)")
        }
        return nil
    }

    static func delete(account: String) {
        // kSecAttrSynchronizableAny catches both synchronizable and non-synchronizable items.
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("SecItemDelete failed for account=\(account, privacy: .public) status=\(status)")
        }
    }
}
