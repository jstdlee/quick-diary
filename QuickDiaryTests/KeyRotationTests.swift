import CryptoKit
import XCTest
@testable import QuickDiary

final class KeyRotationTests: XCTestCase {
    /// Low round count: these tests check behaviour, not strength.
    private let rounds = 1_000
    private var folder: URL!
    private let oldMaster = VaultCrypto.newMasterKey()
    private let newMaster = VaultCrypto.newMasterKey()
    private var keyFile: KeyFile!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        keyFile = try VaultCrypto.makeKeyFile(masterKey: oldMaster, password: "old-pass", iterations: rounds)
        try KeyFileIO.write(keyFile, in: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    /// 3 notes (one with an old date), 1 in Recently Deleted, 1 attachment, 1 Shortcuts item.
    @discardableResult
    private func seed() throws -> (notes: [Note], asset: String) {
        let store = NoteStore(folder: folder, key: oldMaster)
        var notes: [Note] = []
        for title in ["One", "Two", "Three", "Gone"] {
            notes.append(try store.save(text: "# \(title)\nsecret words", id: nil, now: Date()))
        }
        try FileManager.default.setAttributes([.modificationDate: date("2026-01-02 03:04")],
                                              ofItemAtPath: folder.appendingPathComponent(notes[0].id).path)
        try store.delete(id: notes[3].id)
        let asset = try AssetStore(folder: folder, key: oldMaster).add(jpeg: Data((0..<2048).map { UInt8($0 % 251) }))
        try Inbox.add(InboxItem(date: Date(), text: "8,214 steps", source: "Health"), folder: folder, keyFile: keyFile)
        return (notes, asset)
    }

    @discardableResult
    private func rotate(cancelAfter: Int? = nil) throws -> RotationProgress {
        let begun = try KeyRotation.begin(folder: folder, keyFile: keyFile, oldPassword: "old-pass", newPassword: "new-pass",
                                          newMaster: newMaster, iterations: rounds)
        let cancel = CancelFlag()
        return try KeyRotation.run(folder: folder, rotation: begun.rotation, old: begun.old, new: newMaster,
                                   oldKeyFile: keyFile, cancel: cancel) { p in
            if let cancelAfter, p.done >= cancelAfter { cancel.cancel() }
        }
    }

    func testStatsCountEveryEncryptedFile() throws {
        try seed()
        let stats = KeyRotation.stats(in: folder)
        XCTAssertEqual(stats.notes, 3)
        XCTAssertEqual(stats.deleted, 1)
        XCTAssertEqual(stats.attachments, 1)
        XCTAssertEqual(stats.inbox, 1)
        XCTAssertEqual(stats.total, 6)
        XCTAssertEqual(stats.downloading, 0)
        XCTAssertGreaterThan(stats.bytes, 2048)
    }

    func testRotationReencryptsEverything() throws {
        let (notes, asset) = try seed()
        let result = try rotate()
        XCTAssertEqual(result.done, 6)
        XCTAssertEqual(result.alreadyNew, 0)
        XCTAssertEqual(result.unreadable, 0)

        // The new key opens everything…
        let store = NoteStore(folder: folder, key: newMaster)
        XCTAssertEqual(store.list().notes.count, 3)
        XCTAssertEqual(store.list().unreadable, 0)
        XCTAssertEqual(store.listDeleted().map(\.title), ["Gone"])
        XCTAssertEqual(try AssetStore(folder: folder, key: newMaster).data(asset), Data((0..<2048).map { UInt8($0 % 251) }))
        // …the old one opens nothing.
        let old = NoteStore(folder: folder, key: oldMaster)
        XCTAssertEqual(old.list().notes.count, 0)
        XCTAssertEqual(old.list().unreadable, 3)
        XCTAssertThrowsError(try AssetStore(folder: folder, key: oldMaster).data(asset))
        XCTAssertThrowsError(try old.load(id: notes[0].id))
    }

    func testNewKeyFileReplacesTheOldOne() throws {
        try seed()
        try rotate()
        XCTAssertFalse(RotationIO.exists(in: folder))
        let file = try XCTUnwrap(KeyFileIO.read(in: folder))
        XCTAssertTrue(VaultCrypto.matches(newMaster, file))
        XCTAssertEqual(try VaultCrypto.unwrap(file, password: "new-pass").rawData, newMaster.rawData)
        XCTAssertThrowsError(try VaultCrypto.unwrap(file, password: "old-pass")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
        // The old key file (a backup of it) + the old password still give the old key, which opens nothing now.
        let oldKey = try VaultCrypto.unwrap(keyFile, password: "old-pass")
        XCTAssertEqual(NoteStore(folder: folder, key: oldKey).list().notes.count, 0)
        XCTAssertNotEqual(file.inboxPublicKey, keyFile.inboxPublicKey, "the inbox key pair is new too")
    }

    func testDatesAreKept() throws {
        let (notes, _) = try seed()
        let url = folder.appendingPathComponent(notes[0].id)
        let before = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try rotate()
        let after = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(before, after)
        XCTAssertEqual(after, date("2026-01-02 03:04"))
    }

    func testShortcutsItemsFollowTheNewKey() throws {
        try seed()
        try rotate()
        let file = try XCTUnwrap(KeyFileIO.read(in: folder))
        let privateKey = try VaultCrypto.inboxPrivateKey(file, master: newMaster)
        XCTAssertEqual(Inbox.pending(folder: folder, privateKey: privateKey).map { $0.item.text }, ["8,214 steps"])
    }

    func testPausedRunResumesWithTheNewPasswordOnly() throws {
        try seed()
        XCTAssertThrowsError(try rotate(cancelAfter: 2)) {
            XCTAssertEqual($0 as? VaultError, .rotationPaused)
        }
        // Half done: the rotation file is there and the old key file is still in place.
        let rotation = try XCTUnwrap(RotationIO.read(in: folder))
        XCTAssertTrue(VaultCrypto.matches(oldMaster, try XCTUnwrap(KeyFileIO.read(in: folder))))
        XCTAssertThrowsError(try KeyRotation.open(rotation, newPassword: "old-pass"))

        let keys = try KeyRotation.open(rotation, newPassword: "new-pass")
        XCTAssertEqual(keys.old.rawData, oldMaster.rawData)
        XCTAssertEqual(keys.new.rawData, newMaster.rawData)
        let result = try KeyRotation.run(folder: folder, rotation: rotation, old: keys.old, new: keys.new,
                                         oldKeyFile: try KeyFileIO.read(in: folder), cancel: CancelFlag()) { _ in }
        XCTAssertEqual(result.alreadyNew, 2)
        XCTAssertEqual(result.done, 6)
        XCTAssertFalse(RotationIO.exists(in: folder))
        XCTAssertEqual(NoteStore(folder: folder, key: newMaster).list().notes.count, 3)
    }

    func testShortcutsTextAddedDuringTheReplacementUsesTheNewKey() throws {
        try seed()
        XCTAssertThrowsError(try rotate(cancelAfter: 1))
        try Inbox.add(InboxItem(date: Date(), text: "added meanwhile", source: ""), folder: folder, keyFile: keyFile)
        let rotation = try XCTUnwrap(RotationIO.read(in: folder))
        let keys = try KeyRotation.open(rotation, newPassword: "new-pass")
        try KeyRotation.run(folder: folder, rotation: rotation, old: keys.old, new: keys.new,
                            oldKeyFile: keyFile, cancel: CancelFlag()) { _ in }
        let privateKey = try VaultCrypto.inboxPrivateKey(rotation.next, master: newMaster)
        XCTAssertEqual(Set(Inbox.pending(folder: folder, privateKey: privateKey).map { $0.item.text }),
                       ["8,214 steps", "added meanwhile"])
    }

    func testUnreadableFilesAreLeftAsTheyAre() throws {
        try seed()
        let stranger = try NoteStore(folder: folder, key: VaultCrypto.newMasterKey()).save(text: "not ours", id: nil)
        let before = try Data(contentsOf: folder.appendingPathComponent(stranger.id))
        let result = try rotate()
        XCTAssertEqual(result.unreadable, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(stranger.id)), before)
    }

    func testRotationFileJSONRoundTrip() throws {
        let begun = try KeyRotation.begin(folder: folder, keyFile: keyFile, oldPassword: "old-pass", newPassword: "new-pass",
                                          newMaster: newMaster, iterations: rounds)
        XCTAssertEqual(try RotationIO.read(in: folder), begun.rotation)
        XCTAssertEqual(try VaultCrypto.openPreviousKey(begun.rotation.previousKey, with: newMaster).rawData, oldMaster.rawData)
        XCTAssertThrowsError(try VaultCrypto.openPreviousKey(begun.rotation.previousKey, with: oldMaster))
        XCTAssertNil(String(decoding: try Data(contentsOf: RotationIO.url(in: folder)), as: UTF8.self)
            .range(of: oldMaster.rawData.hex), "the old key is never stored in the clear")
    }

    func testWrongCurrentPasswordChangesNothing() throws {
        try seed()
        XCTAssertThrowsError(try KeyRotation.begin(folder: folder, keyFile: keyFile, oldPassword: "nope", newPassword: "new-pass",
                                                   newMaster: newMaster, iterations: rounds)) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
        XCTAssertFalse(RotationIO.exists(in: folder))
        XCTAssertEqual(NoteStore(folder: folder, key: oldMaster).list().notes.count, 3)
    }
}
