import CryptoKit
import Foundation

/// Replacing the master key ("key rotation"). For when the old key may be known to someone else: the
/// password leaked and an old copy of the key file exists (iCloud versions, backups, an exported copy), or
/// the recovery key leaked. Changing the password is not enough then, because the master key stays the same.
///
/// A new master key re-encrypts every note, deleted note, attachment and waiting Shortcuts item, and gets a
/// new password, recovery key and inbox key pair. Crash-safe:
/// 1. `quick-diary-rotation.json` is written first. It holds the new key file and the old master key sealed
///    with the new one, so the new password alone can finish an interrupted run.
/// 2. Each file is re-encrypted in place (atomic write, dates kept). A file the old key can't open but the new
///    one can was done by an earlier run.
/// 3. The new key file replaces `quick-diary-key.json`, then the rotation file is removed.
/// Other devices that see the rotation file, or a key file that no longer matches their key, lock.
struct RotationFile: Codable, Equatable {
    var format = "quick-diary-rotation"
    var version = 1
    /// Becomes `quick-diary-key.json` when every file is done.
    var next: KeyFile
    /// The old master key, AES-GCM sealed with the new master key.
    var previousKey: Data
    var started: Date
}

enum RotationIO {
    static let fileName = "quick-diary-rotation.json"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    /// Also true for an iCloud placeholder that hasn't downloaded yet.
    static func exists(in folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url(in: folder).path)
            || fm.fileExists(atPath: folder.appendingPathComponent(".\(fileName).icloud").path)
    }

    static func read(in folder: URL) throws -> RotationFile? {
        let url = url(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if exists(in: folder) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw VaultError.keyDownloading
            }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(RotationFile.self, from: Data(contentsOf: url)),
              file.format == "quick-diary-rotation", file.version == 1 else { throw VaultError.badKeyFile }
        return file
    }

    static func write(_ file: RotationFile, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: url(in: folder), options: .atomic)
    }

    static func remove(in folder: URL) throws {
        let url = url(in: folder)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct RotationStats: Equatable {
    var notes = 0
    var deleted = 0
    var attachments = 0
    var inbox = 0
    var bytes: Int64 = 0
    /// Files iCloud hasn't downloaded yet: they can't be re-encrypted until they're on this device.
    var downloading = 0

    var total: Int { notes + deleted + attachments + inbox }
}

struct RotationProgress: Equatable {
    var done = 0
    var total = 0
    /// Already on the new key (an interrupted run did them).
    var alreadyNew = 0
    /// Neither key opens them; left as they are.
    var unreadable = 0
}

/// Set from the main thread (Pause, or iOS ending background time); read by the worker.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

enum KeyRotation {
    enum Kind { case note, deletedNote, asset, inbox }

    private static func entries(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    }

    private static func dirs(in folder: URL) -> [(URL, Kind, String)] {
        [(folder, .note, NoteStore.suffix),
         (folder.appendingPathComponent(NoteStore.trashName, isDirectory: true), .deletedNote, NoteStore.suffix),
         (folder.appendingPathComponent(AssetStore.dirName, isDirectory: true), .asset, AssetStore.suffix),
         (Inbox.dir(in: folder), .inbox, Inbox.suffix)]
    }

    /// Every encrypted file of the vault.
    static func files(in folder: URL) -> [(url: URL, kind: Kind)] {
        var out: [(url: URL, kind: Kind)] = []
        for (dir, kind, suffix) in dirs(in: folder) {
            for url in entries(dir) {
                let name = url.lastPathComponent
                if name.hasSuffix(suffix) && !name.hasPrefix(".") { out.append((url, kind)) }
            }
        }
        return out.sorted { $0.url.path < $1.url.path }
    }

    /// iCloud placeholders of encrypted files. Asks iCloud to download them.
    static func pendingDownloads(in folder: URL) -> [URL] {
        var out: [URL] = []
        for (dir, _, suffix) in dirs(in: folder) {
            for url in entries(dir) {
                let name = url.lastPathComponent
                guard name.hasPrefix("."), name.hasSuffix(suffix + ".icloud") else { continue }
                out.append(url)
                let real = dir.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                try? FileManager.default.startDownloadingUbiquitousItem(at: real)
            }
        }
        return out
    }

    static func stats(in folder: URL) -> RotationStats {
        var stats = RotationStats()
        for file in Self.files(in: folder) {
            switch file.kind {
            case .note: stats.notes += 1
            case .deletedNote: stats.deleted += 1
            case .asset: stats.attachments += 1
            case .inbox: stats.inbox += 1
            }
            stats.bytes += Int64((try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        stats.downloading = pendingDownloads(in: folder).count
        return stats
    }

    /// Step 1: checks the current password and writes the rotation file. Nothing else changes yet.
    static func begin(folder: URL, keyFile: KeyFile, oldPassword: String, newPassword: String,
                      newMaster: SymmetricKey, iterations: Int) throws -> (old: SymmetricKey, rotation: RotationFile) {
        let old = try VaultCrypto.unwrap(keyFile, password: oldPassword)
        let next = try VaultCrypto.makeKeyFile(masterKey: newMaster, password: newPassword, iterations: iterations)
        let rotation = RotationFile(
            next: next,
            previousKey: try VaultCrypto.sealPreviousKey(old, with: newMaster),
            started: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        try RotationIO.write(rotation, in: folder)
        return (old, rotation)
    }

    /// For resuming: both keys from the rotation file and the new password.
    static func open(_ rotation: RotationFile, newPassword: String) throws -> (old: SymmetricKey, new: SymmetricKey) {
        let new = try VaultCrypto.unwrap(rotation.next, password: newPassword)
        return (try VaultCrypto.openPreviousKey(rotation.previousKey, with: new), new)
    }

    enum Outcome { case reencrypted, alreadyNew, unreadable }

    struct Keys {
        let old: SymmetricKey
        let new: SymmetricKey
        /// nil when the old key file is gone (an earlier run already finished the key file).
        let oldInbox: Curve25519.KeyAgreement.PrivateKey?
        let newInbox: Curve25519.KeyAgreement.PrivateKey
        let newInboxPublic: Data
    }

    /// Re-encrypts one file in place. The file keeps its dates: the notes list sorts by them, and
    /// Recently Deleted counts its 30 days from them.
    static func reencrypt(_ url: URL, kind: Kind, keys: Keys) throws -> Outcome {
        let data = try Data(contentsOf: url)
        let output: Data
        switch kind {
        case .note, .deletedNote:
            if let text = try? VaultCrypto.decryptNote(data, key: keys.old) {
                output = try VaultCrypto.encryptNote(text, key: keys.new)
            } else if (try? VaultCrypto.decryptNote(data, key: keys.new)) != nil {
                return .alreadyNew
            } else {
                return .unreadable
            }
        case .asset:
            if let plain = try? VaultCrypto.decryptAsset(data, key: keys.old) {
                output = try VaultCrypto.encryptAsset(plain, key: keys.new)
            } else if (try? VaultCrypto.decryptAsset(data, key: keys.new)) != nil {
                return .alreadyNew
            } else {
                return .unreadable
            }
        case .inbox:
            if let oldInbox = keys.oldInbox, let plain = try? VaultCrypto.openInbox(data, privateKey: oldInbox) {
                output = try VaultCrypto.sealToInbox(plain, publicKey: keys.newInboxPublic)
            } else if (try? VaultCrypto.openInbox(data, privateKey: keys.newInbox)) != nil {
                return .alreadyNew
            } else {
                return .unreadable
            }
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        try output.write(to: url, options: .atomic)
        var attributes: [FileAttributeKey: Any] = [:]
        if let date = values?.contentModificationDate { attributes[.modificationDate] = date }
        if let date = values?.creationDate { attributes[.creationDate] = date }
        if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path) }
        return .reencrypted
    }

    /// Steps 2 and 3. Throws `rotationPaused` when cancelled; the rotation file stays, so it can be resumed.
    @discardableResult
    static func run(folder: URL, rotation: RotationFile, old: SymmetricKey, new: SymmetricKey, oldKeyFile: KeyFile?,
                    cancel: CancelFlag, progress: @escaping (RotationProgress) -> Void) throws -> RotationProgress {
        guard pendingDownloads(in: folder).isEmpty else { throw VaultError.filesDownloading }
        guard let newPublic = rotation.next.inboxPublicKey else { throw VaultError.badKeyFile }
        let keys = Keys(old: old, new: new,
                        oldInbox: oldKeyFile.flatMap { try? VaultCrypto.inboxPrivateKey($0, master: old) },
                        newInbox: try VaultCrypto.inboxPrivateKey(rotation.next, master: new),
                        newInboxPublic: newPublic)
        let all = Self.files(in: folder)
        var p = RotationProgress(total: all.count)
        progress(p)
        for file in all {
            if cancel.isCancelled { throw VaultError.rotationPaused }
            switch try reencrypt(file.url, kind: file.kind, keys: keys) {
            case .reencrypted: break
            case .alreadyNew: p.alreadyNew += 1
            case .unreadable: p.unreadable += 1
            }
            p.done += 1
            progress(p)
        }
        // Every file is on the new key: make it the vault's key, then drop the rotation file (it holds the old key).
        try KeyFileIO.write(rotation.next, in: folder)
        try RotationIO.remove(in: folder)
        return p
    }
}
