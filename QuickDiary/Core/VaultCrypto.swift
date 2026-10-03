import CommonCrypto
import CryptoKit
import Foundation

/// Errors shown to the user. Messages say what happened and what to do.
enum VaultError: LocalizedError, Equatable {
    case wrongPassword
    case passwordTooShort
    case passwordsDiffer
    case badKeyFile
    case badRecoveryKey
    case recoveryKeyMismatch
    case badNote
    case locked
    case folderUnavailable
    case iCloudUnavailable
    case keyDownloading

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            String(localized: "Wrong password. Try again, or use your recovery key.")
        case .passwordTooShort:
            String(localized: "Use at least 6 characters.")
        case .passwordsDiffer:
            String(localized: "The two passwords are different.")
        case .badKeyFile:
            String(localized: "This is not a Quick Diary key file.")
        case .badRecoveryKey:
            String(localized: "A recovery key has 64 characters (0–9, A–F). Check it and try again.")
        case .recoveryKeyMismatch:
            String(localized: "This recovery key does not open the notes in this folder.")
        case .badNote:
            String(localized: "A note can't be decrypted.")
        case .locked:
            String(localized: "Unlock Quick Diary first.")
        case .folderUnavailable:
            String(localized: "The notes folder can't be opened. Choose it again in Settings.")
        case .iCloudUnavailable:
            String(localized: "iCloud Drive isn't available. Sign in to iCloud, or choose a folder in iCloud Drive with Folder….")
        case .keyDownloading:
            String(localized: "The key file is still downloading from iCloud. Try again in a moment.")
        }
    }
}

/// The vault key file (`quick-diary-key.json`). It holds the random master key,
/// encrypted with a key derived from the password. Notes are encrypted with the
/// master key, so changing the password only rewrites this file.
struct KeyFile: Codable, Equatable {
    var format = "quick-diary-key"
    var version = 1
    var kdf = "PBKDF2-HMAC-SHA256"
    var iterations: Int
    var salt: Data
    /// AES-256-GCM sealed box (nonce + ciphertext + tag) of the master key.
    var wrappedKey: Data
    /// First 16 bytes of HMAC-SHA256(master key, "quick-diary-check"):
    /// lets a recovery key be checked without the password.
    var check: Data
    var created: Date
    /// Curve25519 public key. Shortcuts can encrypt text to it while the app is locked.
    var inboxPublicKey: Data?
    /// The matching private key, sealed with the master key.
    var inboxPrivateKey: Data?
}

enum VaultCrypto {
    static let defaultIterations = 600_000
    static let minPasswordLength = 6

    static let noteMagic = Data("QDN1".utf8)
    private static let keyAAD = Data("quick-diary-key-v1".utf8)
    private static let noteAAD = Data("quick-diary-note-v1".utf8)
    private static let checkLabel = Data("quick-diary-check".utf8)
    private static let inboxKeyAAD = Data("quick-diary-inbox-key-v1".utf8)
    private static let inboxInfo = Data("quick-diary-inbox-v1".utf8)
    private static let assetAAD = Data("quick-diary-asset-v1".utf8)
    static let inboxMagic = Data("QDI1".utf8)
    static let assetMagic = Data("QDA1".utf8)

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }

    static func newMasterKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// PBKDF2-HMAC-SHA256 → 256-bit key. The password is NFC-normalized so the same
    /// password typed on different keyboards gives the same key.
    static func deriveKey(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let normalized = password.precomposedStringWithCanonicalMapping
        let length = normalized.utf8.count
        var out = [UInt8](repeating: 0, count: 32)
        let status = normalized.withCString { pwPtr in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr, length,
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &out, out.count)
            }
        }
        precondition(status == Int32(kCCSuccess), "PBKDF2 failed")
        return SymmetricKey(data: out)
    }

    static func checkValue(for master: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: checkLabel, using: master)).prefix(16)
    }

    static func makeKeyFile(masterKey: SymmetricKey, password: String,
                            iterations: Int = defaultIterations) throws -> KeyFile {
        let salt = randomBytes(16)
        let kek = deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(masterKey.rawData, using: kek, authenticating: keyAAD)
        var file = KeyFile(iterations: iterations, salt: salt, wrappedKey: sealed.combined!,
                           check: checkValue(for: masterKey),
                           // Whole seconds: the JSON (ISO 8601) keeps no fractions.
                           created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        try addInboxKeys(to: &file, master: masterKey)
        return file
    }

    // MARK: Inbox — Shortcuts add text while the vault is locked

    static func addInboxKeys(to file: inout KeyFile, master: SymmetricKey) throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        file.inboxPublicKey = privateKey.publicKey.rawRepresentation
        file.inboxPrivateKey = try AES.GCM.seal(privateKey.rawRepresentation, using: master,
                                                authenticating: inboxKeyAAD).combined
    }

    static func inboxPrivateKey(_ file: KeyFile, master: SymmetricKey) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let sealed = file.inboxPrivateKey else { throw VaultError.badKeyFile }
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: master, authenticating: inboxKeyAAD)
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    private static func inboxKey(shared: SharedSecret, ephemeral: Data, recipient: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + recipient,
                                       sharedInfo: inboxInfo, outputByteCount: 32)
    }

    /// "QDI1" + ephemeral public key (32) + AES-GCM box. Only the vault's private key opens it.
    static func sealToInbox(_ plaintext: Data, publicKey: Data) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = inboxKey(shared: shared, ephemeral: ephemeral.publicKey.rawRepresentation, recipient: publicKey)
        let box = try AES.GCM.seal(plaintext, using: key)
        return inboxMagic + ephemeral.publicKey.rawRepresentation + box.combined!
    }

    static func openInbox(_ data: Data, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 4 + 32, Data(bytes[0..<4]) == inboxMagic else { throw VaultError.badNote }
        let ephemeralRaw = Data(bytes[4..<36])
        do {
            let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralRaw)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let key = inboxKey(shared: shared, ephemeral: ephemeralRaw,
                               recipient: privateKey.publicKey.rawRepresentation)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(bytes[36...])), using: key)
        } catch {
            throw VaultError.badNote
        }
    }

    // MARK: Attachments — "QDA1" + AES-256-GCM box of the file bytes

    static func encryptAsset(_ data: Data, key: SymmetricKey) throws -> Data {
        assetMagic + (try AES.GCM.seal(data, using: key, authenticating: assetAAD).combined!)
    }

    static func decryptAsset(_ data: Data, key: SymmetricKey) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 4, Data(bytes[0..<4]) == assetMagic else { throw VaultError.badNote }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(bytes[4...])), using: key,
                                    authenticating: assetAAD)
        } catch {
            throw VaultError.badNote
        }
    }

    static func unwrap(_ file: KeyFile, password: String) throws -> SymmetricKey {
        guard file.format == "quick-diary-key", file.version == 1 else { throw VaultError.badKeyFile }
        let kek = deriveKey(password: password, salt: file.salt, iterations: file.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: file.wrappedKey)
            return SymmetricKey(data: try AES.GCM.open(box, using: kek, authenticating: keyAAD))
        } catch {
            throw VaultError.wrongPassword
        }
    }

    static func matches(_ master: SymmetricKey, _ file: KeyFile) -> Bool {
        checkValue(for: master) == file.check
    }

    // MARK: Notes — "QDN1" + AES-256-GCM sealed box of the UTF-8 Markdown

    static func encryptNote(_ text: String, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(Data(text.utf8), using: key, authenticating: noteAAD)
        return noteMagic + box.combined!
    }

    static func decryptNote(_ data: Data, key: SymmetricKey) throws -> String {
        guard data.count > noteMagic.count, data.prefix(noteMagic.count) == noteMagic else {
            throw VaultError.badNote
        }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(noteMagic.count)))
            let plain = try AES.GCM.open(box, using: key, authenticating: noteAAD)
            return String(decoding: plain, as: UTF8.self)
        } catch {
            throw VaultError.badNote
        }
    }

    // MARK: Recovery key — the master key as 16 groups of 4 hex digits

    static func recoveryString(_ key: SymmetricKey) -> String {
        let hex = key.rawData.hex.uppercased()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    static func parseRecovery(_ text: String) throws -> SymmetricKey {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 64, let data = Data(hex: hex) else { throw VaultError.badRecoveryKey }
        return SymmetricKey(data: data)
    }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
