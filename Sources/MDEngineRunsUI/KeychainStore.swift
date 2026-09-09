#if os(iOS)
import Foundation
import Security

/// The tracker's key store on iOS: the Keychain, not a file.
///
/// The reasoning, since the cheap option was right there: the API key is a bearer token against a balance
/// someone paid for, and a file under Application Support is included in an unencrypted iTunes/Finder backup
/// unless explicitly excluded. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is both encrypted at rest and
/// excluded from backups by construction, so a stolen backup does not hand over the ability to spend GPU
/// credit. The cost is that reinstalling the app means pasting the key again, which is the right trade for
/// something that moves money.
public struct KeychainCredentialStore: CredentialStore {
    let service: String
    let account: String

    public init(service: String = "com.forcefieldsilicon.mdengine.runs", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        // Update in place if present; a delete-then-add would leave the app keyless if the add failed.
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status, op: "update") }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus, op: "add") }
    }

    public func clear() { SecItemDelete(baseQuery as CFDictionary) }

    /// Can this bundle actually use the Keychain? Answered by trying, not by inspecting entitlements:
    /// -34018 (errSecMissingEntitlement) is only observable at the call. Writes and removes a throwaway
    /// item under a separate account so a real stored key is never touched.
    public var isUsable: Bool {
        let probe = KeychainCredentialStore(service: service, account: account + ".probe")
        defer { probe.clear() }
        do { try probe.save("probe"); return probe.load() == "probe" }
        catch { return false }
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public let op: String
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "could not \(op) the key in the Keychain: \(detail)"
    }
}
#endif
