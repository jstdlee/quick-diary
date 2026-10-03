import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Face ID / Touch ID unlock: the master key in the Keychain, readable only after biometric
/// authentication on this device. A new fingerprint or face enrolment invalidates it.
enum Biometrics {
    private static let service = "quick-diary.vault-key"

    /// nil when biometrics can be used; otherwise the reason it can't.
    static var unavailableReason: String? {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return nil }
        switch LAError.Code(rawValue: error?.code ?? 0) {
        case .biometryNotEnrolled: return String(localized: "Set up \(name) in the Settings app first.")
        case .passcodeNotSet: return String(localized: "Set a device passcode in the Settings app first.")
        default: return String(localized: "This device has no Face ID or Touch ID.")
        }
    }

    static var name: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }

    static var symbol: String {
        name == "Touch ID" ? "touchid" : name == "Optic ID" ? "opticid" : "faceid"
    }

    static func save(_ key: SymmetricKey, account: String) throws {
        remove(account: account)
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil) else {
            throw VaultError.locked
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: key.rawData,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.locked }
    }

    /// Asks for Face ID, then returns the key.
    static func load(account: String, reason: String) async throws -> SymmetricKey {
        try await Task.detached {
            let context = LAContext()
            context.localizedReason = reason
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { throw VaultError.locked }
            return SymmetricKey(data: data)
        }.value
    }

    /// True when a key is stored (checks without showing Face ID).
    static func has(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
