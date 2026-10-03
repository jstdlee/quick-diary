import CryptoKit
import Foundation

struct Note: Identifiable, Hashable {
    /// File name, e.g. `2026-10-03_1432.md.enc`.
    let id: String
    var text: String
    var modified: Date

    var title: String {
        let first = Self.contentLines(text).first ?? ""
        let title = first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? String(localized: "Untitled") : title
    }

    /// The text after the title, with Markdown markers removed, on one line.
    var preview: String {
        Self.contentLines(text).dropFirst()
            .map { line in
                var s = Substring(line)
                for marker in ["- [ ] ", "- [x] ", "- ", "* ", "> ", "#"] where s.hasPrefix(marker) {
                    s = s.dropFirst(marker.count)
                }
                return s.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
            }
            .joined(separator: " ")
            .prefix(160)
            .description
    }

    private static func contentLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// The key file lives next to the notes, so a folder (local, iCloud, shared) is a whole vault.
enum KeyFileIO {
    static let fileName = "quick-diary-key.json"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    static func encode(_ file: KeyFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> KeyFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(KeyFile.self, from: data),
              file.format == "quick-diary-key" else { throw VaultError.badKeyFile }
        return file
    }

    /// nil when the folder has no key file yet.
    static func read(in folder: URL) throws -> KeyFile? {
        let url = url(in: folder)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return try decode(Data(contentsOf: url))
        }
        // iCloud keeps files it hasn't downloaded as ".name.icloud" placeholders.
        let placeholder = folder.appendingPathComponent(".\(fileName).icloud")
        if fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            throw VaultError.keyDownloading
        }
        return nil
    }

    static func write(_ file: KeyFile, in folder: URL) throws {
        try encode(file).write(to: url(in: folder), options: .atomic)
    }
}

/// Encrypted Markdown notes in one folder: `yyyy-MM-dd_HHmm.md.enc`.
struct NoteStore {
    static let suffix = ".md.enc"

    let folder: URL
    let key: SymmetricKey

    static func noteFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter {
            let name = $0.lastPathComponent
            return name.hasSuffix(suffix) && !name.hasPrefix(".")
        }
    }

    static func hasNotes(in folder: URL) -> Bool {
        !noteFiles(in: folder).isEmpty || !placeholders(in: folder).isEmpty
    }

    /// Notes iCloud hasn't downloaded yet.
    static func placeholders(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(".") && $0.hasSuffix(suffix + ".icloud") }
            .map { folder.appendingPathComponent($0) }
    }

    struct Listing {
        var notes: [Note]
        var unreadable: Int
        var downloading: Int
    }

    func list() -> Listing {
        let pending = Self.placeholders(in: folder)
        for placeholder in pending {
            let name = String(placeholder.lastPathComponent.dropFirst().dropLast(".icloud".count))
            try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(name))
        }
        var notes: [Note] = []
        var unreadable = 0
        for url in Self.noteFiles(in: folder) {
            if let note = try? load(id: url.lastPathComponent) { notes.append(note) } else { unreadable += 1 }
        }
        notes.sort { ($0.modified, $0.id) > ($1.modified, $1.id) }
        return Listing(notes: notes, unreadable: unreadable, downloading: pending.count)
    }

    func load(id: String) throws -> Note {
        let url = folder.appendingPathComponent(id)
        let text = try VaultCrypto.decryptNote(Data(contentsOf: url), key: key)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return Note(id: id, text: text, modified: modified)
    }

    @discardableResult
    func save(text: String, id: String?, now: Date = Date()) throws -> Note {
        let id = id ?? Self.newID(for: now, in: folder)
        try VaultCrypto.encryptNote(text, key: key)
            .write(to: folder.appendingPathComponent(id), options: .atomic)
        return Note(id: id, text: text, modified: now)
    }

    // MARK: Recently Deleted — a subfolder; notes stay encrypted there

    static let trashName = "Recently Deleted"

    var trash: URL { folder.appendingPathComponent(Self.trashName, isDirectory: true) }

    /// Moves the note to Recently Deleted. It can be restored.
    func delete(id: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let target = trash.appendingPathComponent(id)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: folder.appendingPathComponent(id), to: target)
        // The date in Recently Deleted is the deletion date; it starts the 30 days.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
    }

    func listDeleted() -> [Note] {
        NoteStore(folder: trash, key: key).list().notes
    }

    /// Moves a deleted note back. Returns its id (a new one if the name is taken again).
    @discardableResult
    func restore(id: String) throws -> String {
        var name = id
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(id).path) {
            let base = String(id.dropLast(Self.suffix.count))
            var n = 2
            repeat { name = "\(base)-\(n)\(Self.suffix)"; n += 1 }
            while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        try FileManager.default.moveItem(at: trash.appendingPathComponent(id),
                                         to: folder.appendingPathComponent(name))
        return name
    }

    /// Removes a deleted note for good.
    func purge(id: String) throws {
        try FileManager.default.removeItem(at: trash.appendingPathComponent(id))
    }

    /// True when the key opens at least one note (or there are none to test).
    func opensExistingNotes() -> Bool {
        let files = Self.noteFiles(in: folder)
        return files.isEmpty || files.contains { (try? load(id: $0.lastPathComponent)) != nil }
    }

    static func newID(for date: Date, in folder: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let base = formatter.string(from: date)
        var name = base + suffix
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(n)\(suffix)"
            n += 1
        }
        return name
    }

    /// Copies notes that the destination doesn't have yet. Never overwrites, never deletes.
    @discardableResult
    static func copyNotes(from source: URL, to destination: URL) throws -> Int {
        var copied = 0
        for file in noteFiles(in: source) {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: file, to: target)
                copied += 1
            }
        }
        return copied
    }
}

/// Where the vault folder lives.
enum StorageKind: String, CaseIterable, Identifiable {
    case local, iCloud, folder
    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: String(localized: "On this iPhone")
        case .iCloud: String(localized: "iCloud Drive")
        case .folder: String(localized: "Folder…")
        }
    }
}

enum Storage {
    static let folderName = "Quick Diary"

    /// Documents/Quick Diary — shows in Files › On My iPhone › Quick Diary.
    static func localFolder() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// The app's iCloud Drive folder. nil without iCloud (or without the iCloud entitlement).
    static func iCloudFolder() async -> URL? {
        await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
        }.value
    }

    /// A bookmark keeps access to a folder picked in Files (any provider, shared iCloud folders too).
    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}
