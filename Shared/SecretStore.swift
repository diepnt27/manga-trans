import Foundation
import Security

/// Lưu API key trong Keychain (được mã hoá, không nằm dạng chữ thường trong UserDefaults/bản sao lưu).
/// Có bộ nhớ đệm vì cài đặt được đọc rất thường xuyên.
enum SecretStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "MangaTrans") + ".secrets"
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var migrated = false

    static func value(for account: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        migrateFromDefaultsIfNeeded()
        if let cached = cache[account] { return cached }
        let value = readKeychain(account) ?? fallbackDefaults.string(forKey: fallbackKey(account)) ?? ""
        cache[account] = value
        return value
    }

    static func set(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        cache[account] = trimmed
        if writeKeychain(trimmed, account: account) {
            fallbackDefaults.removeObject(forKey: fallbackKey(account))
        } else {
            // Keychain không dùng được (app ký thiếu quyền) — vẫn lưu được để app không hỏng.
            fallbackDefaults.set(trimmed, forKey: fallbackKey(account))
        }
    }

    // MARK: - Chuyển key cũ (bản trước lưu trong UserDefaults của App Group)

    private static func migrateFromDefaultsIfNeeded() {
        guard !migrated else { return }
        migrated = true
        for account in [SettingsKey.geminiKey, SettingsKey.deepseekKey, SettingsKey.googleCloudKey] {
            guard let old = AppGroup.defaults.string(forKey: account) else { continue }
            if !old.isEmpty, (readKeychain(account) ?? "").isEmpty, writeKeychain(old, account: account) {
                cache[account] = old
            }
            if !(readKeychain(account) ?? "").isEmpty || old.isEmpty {
                AppGroup.defaults.removeObject(forKey: account)
            }
        }
    }

    // MARK: - Keychain

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func writeKeychain(_ value: String, account: String) -> Bool {
        let query = baseQuery(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Chỉ đọc được khi máy đã mở khoá ít nhất 1 lần, không chép sang máy khác qua bản sao lưu.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static let fallbackDefaults = UserDefaults.standard
    private static func fallbackKey(_ account: String) -> String { "secret." + account }
}
