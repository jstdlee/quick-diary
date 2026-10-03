import CryptoKit
import XCTest
@testable import QuickDiary

final class NoteStoreTests: XCTestCase {
    private var folder: URL!
    private let key = VaultCrypto.newMasterKey()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    func testSaveUsesDateNameAndAvoidsCollisions() throws {
        let store = NoteStore(folder: folder, key: key)
        let a = try store.save(text: "# A", id: nil, now: date("2026-10-03 14:32"))
        let b = try store.save(text: "# B", id: nil, now: date("2026-10-03 14:32"))
        XCTAssertEqual(a.id, "2026-10-03_1432.md.enc")
        XCTAssertEqual(b.id, "2026-10-03_1432-2.md.enc")
    }

    func testListDecryptsNewestFirst() throws {
        let store = NoteStore(folder: folder, key: key)
        for (stamp, title) in [("2026-10-01 09:00", "Old"), ("2026-10-03 09:00", "New")] {
            let note = try store.save(text: "# \(title)", id: nil, now: date(stamp))
            try FileManager.default.setAttributes([.modificationDate: date(stamp)],
                                                  ofItemAtPath: folder.appendingPathComponent(note.id).path)
        }
        let listing = store.list()
        XCTAssertEqual(listing.notes.map(\.title), ["New", "Old"])
        XCTAssertEqual(listing.unreadable, 0)
    }

    func testFilesOnDiskAreEncrypted() throws {
        let note = try NoteStore(folder: folder, key: key).save(text: "secret diary words", id: nil)
        let raw = try Data(contentsOf: folder.appendingPathComponent(note.id))
        XCTAssertNil(raw.range(of: Data("secret".utf8)))
    }

    func testUpdateAndDelete() throws {
        let store = NoteStore(folder: folder, key: key)
        let note = try store.save(text: "v1", id: nil)
        try store.save(text: "v2", id: note.id)
        XCTAssertEqual(try store.load(id: note.id).text, "v2")
        try store.delete(id: note.id)
        XCTAssertTrue(store.list().notes.isEmpty)
    }

    func testWrongKeyCountsAsUnreadable() throws {
        try NoteStore(folder: folder, key: key).save(text: "x", id: nil)
        let other = NoteStore(folder: folder, key: VaultCrypto.newMasterKey())
        XCTAssertEqual(other.list().unreadable, 1)
        XCTAssertFalse(other.opensExistingNotes())
        XCTAssertTrue(NoteStore(folder: folder, key: key).opensExistingNotes())
    }

    func testCopyNeverOverwrites() throws {
        let destination = folder.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let note = try NoteStore(folder: folder, key: key).save(text: "original", id: nil)
        try NoteStore(folder: destination, key: key).save(text: "already there", id: note.id)
        XCTAssertEqual(try NoteStore.copyNotes(from: folder, to: destination), 0)
        XCTAssertEqual(try NoteStore(folder: destination, key: key).load(id: note.id).text, "already there")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(note.id).path))
    }

    func testKeyFileReadWrite() throws {
        XCTAssertNil(try KeyFileIO.read(in: folder))
        let file = try VaultCrypto.makeKeyFile(masterKey: key, password: "secret1", iterations: 1_000)
        try KeyFileIO.write(file, in: folder)
        XCTAssertEqual(try KeyFileIO.read(in: folder), file)
    }

    func testAssetsAreEncryptedAndListedLargestFirst() throws {
        let assets = AssetStore(folder: folder, key: key)
        let small = try assets.add(jpeg: Data(repeating: 1, count: 100))
        let large = try assets.add(jpeg: Data(repeating: 2, count: 5000))
        XCTAssertTrue(small.hasPrefix("assets/"))
        XCTAssertEqual(assets.list().map(\.id), [large, small])
        XCTAssertEqual(try assets.data(small), Data(repeating: 1, count: 100))
        let raw = try Data(contentsOf: folder.appendingPathComponent(large))
        XCTAssertNil(raw.range(of: Data(repeating: 2, count: 64)))
    }

    func testDeletingANoteKeepsItsAttachments() throws {
        let store = NoteStore(folder: folder, key: key)
        let assets = AssetStore(folder: folder, key: key)
        let path = try assets.add(jpeg: Data(repeating: 3, count: 10))
        let note = try store.save(text: "![Photo](\(path))", id: nil)
        try store.delete(id: note.id)
        XCTAssertEqual(assets.list().count, 1)
        XCTAssertEqual(store.listDeleted().map(\.id), [note.id])
    }

    func testQuickListLine() {
        let mood = QuickList.defaults[0]
        XCTAssertEqual(mood.line(for: "🙂 Good"), "- Mood: 🙂 Good")
        let decoded = try? JSONDecoder().decode([QuickList].self, from: JSONEncoder().encode(QuickList.defaults))
        XCTAssertEqual(decoded, QuickList.defaults)
    }

    func testTitleAndPreview() {
        let note = Note(id: "x", text: "\n# Morning run\n\n- 📍 Riverside\n- [x] **Stretch**\n", modified: Date())
        XCTAssertEqual(note.title, "Morning run")
        XCTAssertEqual(note.preview, "📍 Riverside Stretch")
        XCTAssertEqual(Note(id: "y", text: "   ", modified: Date()).title, "Untitled")
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let text = """
        # Title
        Some *text*
        continues here

        - item
        - [ ] todo
        - [x] done
        2. second
        > quote
        ---
        ```
        let x = 1
        ```
        """
        XCTAssertEqual(MarkdownPreview.parse(text), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some *text*\ncontinues here"),
            .bullet("item"),
            .task(done: false, text: "todo"),
            .task(done: true, text: "done"),
            .numbered(number: "2", text: "second"),
            .quote("quote"),
            .rule,
            .code("let x = 1"),
        ])
    }

    func testImageLine() {
        XCTAssertEqual(MarkdownPreview.parse("![Sunrise](assets/2026-10-03_0705-1.jpg.enc)"),
                       [.image(alt: "Sunrise", path: "assets/2026-10-03_0705-1.jpg.enc")])
        XCTAssertEqual(MarkdownPreview.parse("![](assets/x.jpg.enc)"), [.image(alt: "", path: "assets/x.jpg.enc")])
        XCTAssertEqual(MarkdownPreview.parse("see ![a](b) inline"), [.paragraph("see ![a](b) inline")])
    }

    func testHashWithoutSpaceIsText() {
        XCTAssertEqual(MarkdownPreview.parse("#hashtag"), [.paragraph("#hashtag")])
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    func testDemoVaultFlow() async throws {
        let model = AppModel(arguments: ["-demo"])
        await model.start()
        XCTAssertEqual(model.phase, .locked)

        do {
            try await model.unlock(password: "wrong-pass")
            XCTFail("unlocked with a wrong password")
        } catch {
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }

        try await model.unlock(password: LaunchOptions.demoPassword)
        XCTAssertEqual(model.phase, .unlocked)
        // The two inbox items became one "From Shortcuts" note, newest first.
        XCTAssertEqual(model.notes.count, DemoData.notes.count + 1)
        let shortcuts = try XCTUnwrap(model.notes.first)
        XCTAssertTrue(shortcuts.title.hasPrefix("From Shortcuts"))
        XCTAssertTrue(shortcuts.text.contains("Health: 8,214 steps"))
        XCTAssertTrue(shortcuts.text.contains("Apple Notes: Edited"))
        XCTAssertTrue(model.notes.contains { $0.title == "Morning run" })
        XCTAssertEqual(model.attachments().count, 2)

        try await model.changePassword(current: LaunchOptions.demoPassword, new: "new-pass", confirm: "new-pass")
        let recovery = try await model.recoveryKey(password: "new-pass")
        model.lock()
        try await model.unlock(password: "new-pass")
        XCTAssertEqual(model.notes.count, DemoData.notes.count + 1)

        // Forgot the password: the recovery key sets a new one.
        model.lock()
        try await model.restore(recovery: recovery, newPassword: "third-pass", confirm: "third-pass")
        XCTAssertEqual(model.phase, .unlocked)
        model.lock()
        try await model.unlock(password: "third-pass")
        XCTAssertEqual(model.notes.count, DemoData.notes.count + 1)
    }

    func testFreshVaultSetup() async throws {
        let model = AppModel(arguments: ["-demoFresh"])
        await model.start()
        XCTAssertEqual(model.phase, .setup)
        do {
            _ = try await model.createVault(password: "short", confirm: "short")
            XCTFail("accepted a short password")
        } catch {
            XCTAssertEqual(error as? VaultError, .passwordTooShort)
        }
        let recovery = try await model.createVault(password: "long-enough", confirm: "long-enough")
        XCTAssertEqual(recovery.count, 79)
        model.finishSetup()
        try model.save(text: "# First", id: nil)
        model.lock()
        try await model.unlock(password: "long-enough")
        XCTAssertEqual(model.notes.map(\.title), ["First"])
    }
}
