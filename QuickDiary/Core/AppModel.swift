import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// Launch flags used by UI tests and screenshots. Both use a throwaway temp folder.
struct LaunchOptions {
    /// `-demo`: a seeded vault (password `demo1234`), starts locked.
    var demo = false
    /// `-demoFresh`: an empty folder, starts at "Create a password".
    var fresh = false

    static let demoPassword = "demo1234"

    init(arguments: [String]) {
        demo = arguments.contains("-demo")
        fresh = arguments.contains("-demoFresh")
    }

    var isDemo: Bool { demo || fresh }
}

/// A storage change the user has picked but not confirmed yet.
struct StoragePlan: Identifiable {
    let id = UUID()
    let kind: StorageKind
    let folder: URL
    let bookmark: Data?
    /// The destination already has its own vault: switch and unlock that one.
    let hasVault: Bool
    let notesToCopy: Int
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case folderProblem(String)
        case setup
        case missingKey
        case locked
        case unlocked
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var notes: [Note] = []
    @Published private(set) var deleted: [Note] = []
    /// True while notes are copied to a new storage place.
    @Published private(set) var copying = false
    @Published private(set) var storage: StorageKind = .local
    @Published private(set) var folder: URL?
    @Published private(set) var downloading = 0
    @Published private(set) var unreadable = 0
    /// Face ID / Touch ID can unlock this vault on this device.
    @Published private(set) var biometricsOn = false
    /// Set by the "New entry" Shortcut; the notes list opens a new note and clears it.
    @Published var pendingNewEntry = false

    let options: LaunchOptions
    let iterations: Int

    private var key: SymmetricKey?
    private var keyFile: KeyFile?
    private var scopedURL: URL?
    private var backgroundedAt: Date?
    private let imageCache = NSCache<NSString, UIImage>()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let storage = "storageKind"
        static let bookmark = "folderBookmark"
    }

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        options = LaunchOptions(arguments: arguments)
        // Demo vaults use fewer rounds so UI tests stay fast. Real vaults use 600,000.
        iterations = options.isDemo ? 20_000 : VaultCrypto.defaultIterations
        if !options.isDemo, let raw = defaults.string(forKey: Keys.storage),
           let kind = StorageKind(rawValue: raw) {
            storage = kind
        }
    }

    private var store: NoteStore? {
        guard let folder, let key else { return nil }
        return NoteStore(folder: folder, key: key)
    }

    var hasKeyFile: Bool { keyFile != nil }

    var folderDisplay: String {
        guard let folder else { return "—" }
        switch storage {
        case .local: return String(localized: "On My iPhone › \(Storage.folderName)")
        case .iCloud: return String(localized: "iCloud Drive › \(Storage.folderName)")
        case .folder:
            let parent = folder.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? folder.lastPathComponent : "\(parent) › \(folder.lastPathComponent)"
        }
    }

    // MARK: Opening a folder

    func start() async {
        if options.isDemo {
            startDemo()
        } else {
            await openCurrentStorage()
        }
    }

    func retry() async { await start() }

    private func openCurrentStorage() async {
        phase = .loading
        do {
            try open(folder: try await resolveFolder(storage))
        } catch {
            phase = .folderProblem(error.localizedDescription)
        }
    }

    private func resolveFolder(_ kind: StorageKind) async throws -> URL {
        switch kind {
        case .local:
            return try Storage.localFolder()
        case .iCloud:
            guard let url = await Storage.iCloudFolder() else { throw VaultError.iCloudUnavailable }
            return url
        case .folder:
            guard let data = defaults.data(forKey: Keys.bookmark),
                  let resolved = try? Storage.resolve(bookmark: data) else {
                throw VaultError.folderUnavailable
            }
            let url = resolved.url
            switchAccess(to: url)
            if resolved.stale, let fresh = try? Storage.bookmark(for: url) {
                defaults.set(fresh, forKey: Keys.bookmark)
            }
            return url
        }
    }

    /// Keeps security-scoped access to the one picked folder in use.
    private func switchAccess(to url: URL?) {
        if scopedURL == url { return }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        if let url, url.startAccessingSecurityScopedResource() { scopedURL = url }
    }

    private func open(folder url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        key = nil
        notes = []
        keyFile = try KeyFileIO.read(in: url)
        refreshBiometrics()
        if keyFile != nil {
            phase = .locked
        } else if NoteStore.hasNotes(in: url) {
            phase = .missingKey
        } else {
            phase = .setup
        }
    }

    private func startDemo() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickDiaryDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if options.demo {
                try DemoData.seed(in: url, password: LaunchOptions.demoPassword, iterations: iterations)
            }
            try open(folder: url)
        } catch {
            phase = .folderProblem(error.localizedDescription)
        }
    }

    // MARK: Vault

    static func validate(_ password: String, _ confirm: String) throws {
        guard password.count >= VaultCrypto.minPasswordLength else { throw VaultError.passwordTooShort }
        guard password == confirm else { throw VaultError.passwordsDiffer }
    }

    /// Creates the key file and returns the recovery key. The app opens after `finishSetup()`,
    /// so the recovery key is shown first.
    func createVault(password: String, confirm: String) async throws -> String {
        try Self.validate(password, confirm)
        guard let folder else { throw VaultError.folderUnavailable }
        let master = VaultCrypto.newMasterKey()
        let iterations = self.iterations
        let file = try await Task.detached {
            try VaultCrypto.makeKeyFile(masterKey: master, password: password, iterations: iterations)
        }.value
        try KeyFileIO.write(file, in: folder)
        keyFile = file
        key = master
        return VaultCrypto.recoveryString(master)
    }

    func finishSetup() {
        phase = .unlocked
        reload()
    }

    func unlock(password: String) async throws {
        guard let keyFile else { throw VaultError.badKeyFile }
        let master = try await Task.detached {
            try VaultCrypto.unwrap(keyFile, password: password)
        }.value
        didUnlock(master)
    }

    private func didUnlock(_ master: SymmetricKey) {
        key = master
        // Vaults made before the inbox existed get inbox keys now.
        if var file = keyFile, file.inboxPublicKey == nil, let folder {
            do {
                try VaultCrypto.addInboxKeys(to: &file, master: master)
                try KeyFileIO.write(file, in: folder)
                keyFile = file
            } catch {}
        }
        mergeInbox()
        phase = .unlocked
        reload()
    }

    func lock() {
        guard keyFile != nil else { return }
        key = nil
        notes = []
        deleted = []
        imageCache.removeAllObjects()
        phase = .locked
    }

    // MARK: Auto-lock

    func appDidEnterBackground() { backgroundedAt = Date() }

    /// Locks when the app was away at least `lockAfter` seconds (0 = always).
    func appDidBecomeActive(lockAfter: TimeInterval) {
        defer { backgroundedAt = nil }
        guard let since = backgroundedAt, phase == .unlocked, !options.isDemo else { return }
        if Date().timeIntervalSince(since) >= lockAfter { lock() }
    }

    // MARK: Face ID / Touch ID

    private var biometricAccount: String? { keyFile.map { $0.check.hex } }

    func refreshBiometrics() {
        biometricsOn = biometricAccount.map { Biometrics.has(account: $0) } ?? false
    }

    func setBiometrics(_ on: Bool) throws {
        guard let account = biometricAccount else { return }
        if on {
            guard let key else { throw VaultError.locked }
            try Biometrics.save(key, account: account)
        } else {
            Biometrics.remove(account: account)
        }
        refreshBiometrics()
    }

    func unlockWithBiometrics() async throws {
        guard let account = biometricAccount, let keyFile else { throw VaultError.locked }
        let master = try await Biometrics.load(account: account, reason: String(localized: "Unlock your notes"))
        guard VaultCrypto.matches(master, keyFile) else {
            Biometrics.remove(account: account)
            refreshBiometrics()
            throw VaultError.wrongPassword
        }
        didUnlock(master)
    }

    // MARK: Inbox (Shortcuts while locked)

    static func inboxNoteID(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: day))_shortcuts\(NoteStore.suffix)"
    }

    /// Adds waiting Shortcuts text to one "From Shortcuts" note per day, then removes the inbox files.
    private func mergeInbox() {
        guard let folder, let key, let keyFile,
              let privateKey = try? VaultCrypto.inboxPrivateKey(keyFile, master: key) else { return }
        let pending = Inbox.pending(folder: folder, privateKey: privateKey)
        guard !pending.isEmpty else { return }
        let notesStore = NoteStore(folder: folder, key: key)
        let byDay = Dictionary(grouping: pending) { Calendar.current.startOfDay(for: $0.item.date) }
        for (day, entries) in byDay {
            let id = Self.inboxNoteID(for: day)
            var text = (try? notesStore.load(id: id).text)
                ?? "# From Shortcuts · \(day.formatted(.dateTime.month(.abbreviated).day()))\n"
            for entry in entries {
                let time = entry.item.date.formatted(date: .omitted, time: .shortened)
                let body = entry.item.text.replacingOccurrences(of: "\n", with: "\n  ")
                let source = entry.item.source.isEmpty ? "" : "\(entry.item.source): "
                text += "\n- \(time) · \(source)\(body)"
            }
            do {
                try notesStore.save(text: text, id: id)
                for entry in entries { try? FileManager.default.removeItem(at: entry.file) }
            } catch {}
        }
    }

    /// Only the key file changes: the master key, and so every note, stays the same.
    func changePassword(current: String, new: String, confirm: String) async throws {
        try Self.validate(new, confirm)
        guard let keyFile, let folder else { throw VaultError.locked }
        let iterations = self.iterations
        let updated = try await Task.detached { () throws -> KeyFile in
            let master = try VaultCrypto.unwrap(keyFile, password: current)
            var file = try VaultCrypto.makeKeyFile(masterKey: master, password: new, iterations: iterations)
            if keyFile.inboxPublicKey != nil {
                // Same inbox keys: text added from Shortcuts before the change still opens.
                file.inboxPublicKey = keyFile.inboxPublicKey
                file.inboxPrivateKey = keyFile.inboxPrivateKey
            }
            return file
        }.value
        try KeyFileIO.write(updated, in: folder)
        self.keyFile = updated
    }

    func recoveryKey(password: String) async throws -> String {
        guard let keyFile else { throw VaultError.locked }
        let master = try await Task.detached {
            try VaultCrypto.unwrap(keyFile, password: password)
        }.value
        return VaultCrypto.recoveryString(master)
    }

    /// Forgot the password, or the key file is lost: the recovery key sets a new password.
    func restore(recovery: String, newPassword: String, confirm: String) async throws {
        try Self.validate(newPassword, confirm)
        guard let folder else { throw VaultError.folderUnavailable }
        let master = try VaultCrypto.parseRecovery(recovery)
        if let keyFile {
            guard VaultCrypto.matches(master, keyFile) else { throw VaultError.recoveryKeyMismatch }
        } else {
            guard NoteStore(folder: folder, key: master).opensExistingNotes() else {
                throw VaultError.recoveryKeyMismatch
            }
        }
        let iterations = self.iterations
        var file = try await Task.detached {
            try VaultCrypto.makeKeyFile(masterKey: master, password: newPassword, iterations: iterations)
        }.value
        if let old = keyFile, old.inboxPublicKey != nil {
            file.inboxPublicKey = old.inboxPublicKey
            file.inboxPrivateKey = old.inboxPrivateKey
        }
        try KeyFileIO.write(file, in: folder)
        keyFile = file
        refreshBiometrics()
        didUnlock(master)
    }

    /// Puts a backed-up key file into the current folder. It still needs its password.
    func importKeyFile(from url: URL) throws {
        guard let folder else { throw VaultError.folderUnavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try KeyFileIO.decode(Data(contentsOf: url))
        try KeyFileIO.write(file, in: folder)
        keyFile = file
        key = nil
        phase = .locked
    }

    /// A dated copy of the key file for "Back up key file".
    func keyBackupURL() throws -> URL {
        guard let keyFile else { throw VaultError.locked }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Quick Diary key \(formatter.string(from: Date())).json")
        try KeyFileIO.encode(keyFile).write(to: url, options: .atomic)
        return url
    }

    // MARK: Notes

    func reload() {
        guard let store else { return }
        let listing = store.list()
        notes = listing.notes
        // Recently Deleted keeps notes for 30 days.
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let trash = store.listDeleted()
        for old in trash where old.modified < cutoff { try? store.purge(id: old.id) }
        deleted = trash.filter { $0.modified >= cutoff }
        downloading = listing.downloading
        unreadable = listing.unreadable
    }

    func note(id: String) -> Note? {
        notes.first { $0.id == id } ?? (try? store?.load(id: id))
    }

    @discardableResult
    func save(text: String, id: String?) throws -> Note {
        guard let store else { throw VaultError.locked }
        let note = try store.save(text: text, id: id)
        notes.removeAll { $0.id == note.id }
        notes.insert(note, at: 0)
        return note
    }

    func delete(id: String) {
        try? store?.delete(id: id)
        reload()
    }

    func restoreDeleted(id: String) {
        try? store?.restore(id: id)
        reload()
    }

    func purgeDeleted(ids: [String]) {
        for id in ids { try? store?.purge(id: id) }
        reload()
    }

    // MARK: Attachments

    private var assets: AssetStore? {
        guard let folder, let key else { return nil }
        return AssetStore(folder: folder, key: key)
    }

    /// Encrypts and stores the image; returns the Markdown line for the note.
    func addImage(_ image: UIImage, alt: String = "Photo") throws -> String {
        guard let assets else { throw VaultError.locked }
        let path = try assets.add(image)
        imageCache.setObject(image, forKey: path as NSString)
        return "![\(alt)](\(path))"
    }

    func image(at path: String) async -> UIImage? {
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        guard let assets else { return nil }
        let image = await Task.detached { () -> UIImage? in
            guard let data = try? assets.data(path) else { return nil }
            return UIImage(data: data)
        }.value
        if let image { imageCache.setObject(image, forKey: path as NSString) }
        return image
    }

    func attachments() -> [AssetStore.Info] { assets?.list() ?? [] }

    /// How many notes (including Recently Deleted) link to the attachment.
    func references(to path: String) -> Int {
        (notes + deleted).filter { $0.text.contains(path) }.count
    }

    func deleteAttachment(_ path: String) throws {
        try assets?.delete(path)
        imageCache.removeObject(forKey: path as NSString)
    }

    // MARK: Storage

    /// Looks at the destination before switching, so the user can confirm.
    func plan(for kind: StorageKind, picked: URL? = nil) async throws -> StoragePlan {
        switch kind {
        case .local:
            return makePlan(kind: kind, folder: try Storage.localFolder(), bookmark: nil)
        case .iCloud:
            guard let url = await Storage.iCloudFolder() else { throw VaultError.iCloudUnavailable }
            return makePlan(kind: kind, folder: url, bookmark: nil)
        case .folder:
            guard let picked else { throw VaultError.folderUnavailable }
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            return makePlan(kind: kind, folder: picked, bookmark: try Storage.bookmark(for: picked))
        }
    }

    private func makePlan(kind: StorageKind, folder url: URL, bookmark: Data?) -> StoragePlan {
        let hasVault = (try? KeyFileIO.read(in: url)) != nil
            || FileManager.default.fileExists(atPath: KeyFileIO.url(in: url).path)
        return StoragePlan(kind: kind, folder: url, bookmark: bookmark, hasVault: hasVault,
                           notesToCopy: hasVault ? 0 : NoteStore.noteFiles(in: self.folder ?? url).count)
    }

    /// Copies the vault (key file + notes) when the destination is empty; otherwise opens
    /// the destination's own vault, locked. Notes in the old place are never deleted.
    func apply(_ plan: StoragePlan) async throws {
        let oldFolder = folder
        let oldScoped = scopedURL
        var destination = plan.folder
        var newScoped: URL?
        if plan.kind == .folder, let bookmark = plan.bookmark,
           let url = try? Storage.resolve(bookmark: bookmark).url {
            if url.startAccessingSecurityScopedResource() { newScoped = url }
            destination = url
        }
        defer {
            // Keep old access until copying is done.
            if oldScoped != newScoped { oldScoped?.stopAccessingSecurityScopedResource() }
            scopedURL = newScoped
        }

        if !plan.hasVault, let oldFolder, let keyFile, oldFolder != destination {
            copying = true
            defer { copying = false }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try KeyFileIO.write(keyFile, in: destination)
            try await Task.detached {
                try NoteStore.copyNotes(from: oldFolder, to: destination)
            }.value
            remember(plan)
            folder = destination
            if key != nil { reload() } else { phase = .locked }
        } else {
            remember(plan)
            try open(folder: destination)
        }
    }

    /// From the folder-problem screen: go back to the folder on this iPhone.
    func useLocalStorage() async {
        do {
            try await apply(try await plan(for: .local))
        } catch {
            phase = .folderProblem(error.localizedDescription)
        }
    }

    private func remember(_ plan: StoragePlan) {
        storage = plan.kind
        guard !options.isDemo else { return }
        defaults.set(plan.kind.rawValue, forKey: Keys.storage)
        if let bookmark = plan.bookmark { defaults.set(bookmark, forKey: Keys.bookmark) }
    }
}
