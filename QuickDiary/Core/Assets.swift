import CryptoKit
import Foundation
import UIKit

/// Encrypted attachments in `<vault>/assets/`. Notes link to them as `![Photo](assets/<name>)`.
/// Deleting a note never deletes its attachments; only the Attachments screen does, after asking.
struct AssetStore {
    static let dirName = "assets"
    static let suffix = ".jpg.enc"

    let folder: URL
    let key: SymmetricKey

    var dir: URL { folder.appendingPathComponent(Self.dirName, isDirectory: true) }

    struct Info: Identifiable, Hashable {
        /// Path used in notes, e.g. `assets/2026-10-03_1432-1.jpg.enc`.
        let id: String
        let size: Int64
        let created: Date
        var name: String { (id as NSString).lastPathComponent }
    }

    /// Downscales to 2048 px, stores as encrypted JPEG, returns the path for the note.
    func add(_ image: UIImage, date: Date = Date()) throws -> String {
        guard let jpeg = Self.prepare(image) else { throw VaultError.badNote }
        return try add(jpeg: jpeg, date: date)
    }

    func add(jpeg: Data, date: Date = Date()) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let base = formatter.string(from: date)
        var n = 1
        var name = "\(base)-\(n)\(Self.suffix)"
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            n += 1
            name = "\(base)-\(n)\(Self.suffix)"
        }
        try VaultCrypto.encryptAsset(jpeg, key: key)
            .write(to: dir.appendingPathComponent(name), options: .atomic)
        return "\(Self.dirName)/\(name)"
    }

    func data(_ path: String) throws -> Data {
        try VaultCrypto.decryptAsset(Data(contentsOf: folder.appendingPathComponent(path)), key: key)
    }

    /// Largest first.
    func list() -> [Info] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(Self.suffix) }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Info(id: "\(Self.dirName)/\(url.lastPathComponent)",
                            size: Int64(values?.fileSize ?? 0),
                            created: values?.creationDate ?? .distantPast)
            }
            .sorted { ($0.size, $0.id) > ($1.size, $1.id) }
    }

    func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(path))
    }

    static func prepare(_ image: UIImage, maxSide: CGFloat = 2048) -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
