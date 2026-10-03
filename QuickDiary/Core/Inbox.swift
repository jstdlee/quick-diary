import CryptoKit
import Foundation

/// Text added from Shortcuts or Siri while Quick Diary is locked.
/// Each item is encrypted at once with the vault's inbox public key and merged into a note at the next unlock.
struct InboxItem: Codable {
    var date: Date
    var text: String
    var source: String
}

enum Inbox {
    static let dirName = "inbox"
    static let suffix = ".qdin"

    static func dir(in folder: URL) -> URL { folder.appendingPathComponent(dirName, isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Needs only the key file's public key, so it works while the app is locked.
    static func add(_ item: InboxItem, folder: URL, keyFile: KeyFile) throws {
        guard let publicKey = keyFile.inboxPublicKey else { throw VaultError.badKeyFile }
        let sealed = try VaultCrypto.sealToInbox(encoder.encode(item), publicKey: publicKey)
        let dir = dir(in: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sealed.write(to: dir.appendingPathComponent("\(UUID().uuidString)\(suffix)"), options: .atomic)
    }

    /// Opens every waiting item. Returns them oldest first with their files, so the caller
    /// removes the files only after the text is safely saved in a note.
    static func pending(folder: URL, privateKey: Curve25519.KeyAgreement.PrivateKey) -> [(item: InboxItem, file: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(in: folder), includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let plain = try? VaultCrypto.openInbox(data, privateKey: privateKey),
                      let item = try? decoder.decode(InboxItem.self, from: plain) else { return nil }
                return (item, url)
            }
            .sorted { $0.item.date < $1.item.date }
    }

    /// Where the vault is, for code that runs without the app's model (App Intents).
    static func currentVaultFolder() async throws -> (folder: URL, scoped: URL?) {
        let defaults = UserDefaults.standard
        let kind = StorageKind(rawValue: defaults.string(forKey: "storageKind") ?? "") ?? .local
        switch kind {
        case .local:
            return (try Storage.localFolder(), nil)
        case .iCloud:
            guard let url = await Storage.iCloudFolder() else { throw VaultError.iCloudUnavailable }
            return (url, nil)
        case .folder:
            guard let data = defaults.data(forKey: "folderBookmark"),
                  let url = try? Storage.resolve(bookmark: data).url else { throw VaultError.folderUnavailable }
            return (url, url.startAccessingSecurityScopedResource() ? url : nil)
        }
    }
}
