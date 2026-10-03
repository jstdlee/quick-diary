import CryptoKit
import Foundation

/// S3 / R2 settings. The secret access key is kept in the Keychain (Secrets.s3Secret).
struct BackupConfig: Codable, Equatable {
    var endpoint = ""
    var region = "auto"
    var bucket = ""
    var prefix = "quick-diary"
    var accessKeyID = ""

    static let storageKey = "backupConfig"

    static func load() -> BackupConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(BackupConfig.self, from: data) else { return BackupConfig() }
        return config
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.storageKey) }

    var isComplete: Bool {
        URL(string: endpoint)?.host != nil && !bucket.isEmpty && !accessKeyID.isEmpty
    }

    func store(secret: String) -> S3Store? {
        guard isComplete, let url = URL(string: endpoint) else { return nil }
        return S3Store(endpoint: url, bucket: bucket,
                       signer: SigV4(accessKey: accessKeyID, secretKey: secret,
                                     region: region.isEmpty ? "auto" : region))
    }
}

/// Copies the vault's files (all already encrypted) to an ObjectStore and back.
enum BackupEngine {
    struct Summary: Equatable {
        var uploaded = 0
        var unchanged = 0
        var bytes: Int64 = 0
    }

    /// Every file of the vault, relative to its folder: key file, notes, assets, Recently Deleted, inbox.
    static func localFiles(in folder: URL) -> [(path: String, url: URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.resolvingSymlinksInPath().path
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            var path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { continue }
            path.removeFirst(base.count)
            if path.hasPrefix("/") { path.removeFirst() }
            files.append((path, url))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    static func objectKey(prefix: String, path: String) -> String {
        let clean = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return clean.isEmpty ? path : "\(clean)/\(path)"
    }

    /// Uploads new and changed files (compared by MD5 = ETag of a single-part upload).
    static func backUp(folder: URL, to store: ObjectStore, prefix: String,
                       progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> Summary {
        let files = localFiles(in: folder)
        let remote = try await store.list(prefix: objectKey(prefix: prefix, path: ""))
        var summary = Summary()
        for (index, file) in files.enumerated() {
            progress(index, files.count)
            let data = try Data(contentsOf: file.url)
            let key = objectKey(prefix: prefix, path: file.path)
            let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if remote[key] == md5 {
                summary.unchanged += 1
            } else {
                try await store.put(data, key: key)
                summary.uploaded += 1
                summary.bytes += Int64(data.count)
            }
        }
        progress(files.count, files.count)
        return summary
    }

    /// Downloads files this vault doesn't have. Never replaces a local file.
    static func restoreMissing(folder: URL, from store: ObjectStore, prefix: String,
                               progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> Int {
        let start = objectKey(prefix: prefix, path: "")
        let keys = try await store.list(prefix: start).keys.sorted()
        let local = Set(localFiles(in: folder).map(\.path))
        let missing = keys.compactMap { key -> String? in
            let path = String(key.dropFirst(start.count))
            return path.isEmpty || path.hasSuffix("/") || local.contains(path) || path.contains("..") ? nil : path
        }
        for (index, path) in missing.enumerated() {
            progress(index, missing.count)
            let data = try await store.get(key: objectKey(prefix: prefix, path: path))
            let target = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try data.write(to: target, options: .withoutOverwriting)
        }
        progress(missing.count, missing.count)
        return missing.count
    }

    /// The whole vault as one .zip (still encrypted inside), for Mail, Files or AirDrop.
    static func exportZip(folder: URL) throws -> URL {
        var result: URL?
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipURL in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("Quick Diary backup \(formatter.string(from: Date())).zip")
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: zipURL, to: target)
                result = target
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
        guard let result else { throw VaultError.folderUnavailable }
        return result
    }
}

/// In-memory store for tests and demo mode.
final class MemoryStore: ObjectStore {
    private(set) var objects: [String: Data] = [:]
    private let lock = NSLock()

    func list(prefix: String) async throws -> [String: String] {
        lock.withLock {
            objects.filter { $0.key.hasPrefix(prefix) }.mapValues {
                Insecure.MD5.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            }
        }
    }

    func put(_ data: Data, key: String) async throws { lock.withLock { objects[key] = data } }

    func get(key: String) async throws -> Data {
        guard let data = lock.withLock({ objects[key] }) else { throw S3Error(status: 404, body: "") }
        return data
    }
}
