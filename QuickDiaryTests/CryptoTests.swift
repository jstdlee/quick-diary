import CryptoKit
import XCTest
@testable import QuickDiary

final class CryptoTests: XCTestCase {
    /// Low round count: these tests check behaviour, not strength.
    private let rounds = 1_000

    func testPBKDF2MatchesKnownVectors() {
        // PBKDF2-HMAC-SHA256 test vectors (RFC 7914 §11 style, P="password", S="salt").
        let salt = Data("salt".utf8)
        XCTAssertEqual(VaultCrypto.deriveKey(password: "password", salt: salt, iterations: 1).rawData.hex,
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(VaultCrypto.deriveKey(password: "password", salt: salt, iterations: 2).rawData.hex,
                       "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(VaultCrypto.deriveKey(password: "password", salt: salt, iterations: 4096).rawData.hex,
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testKeyFileUnwrapsWithRightPassword() throws {
        let master = VaultCrypto.newMasterKey()
        let file = try VaultCrypto.makeKeyFile(masterKey: master, password: "secret1", iterations: rounds)
        XCTAssertEqual(try VaultCrypto.unwrap(file, password: "secret1").rawData, master.rawData)
        XCTAssertNotEqual(file.wrappedKey, master.rawData)
    }

    func testWrongPasswordIsRejected() throws {
        let file = try VaultCrypto.makeKeyFile(masterKey: VaultCrypto.newMasterKey(), password: "secret1", iterations: rounds)
        XCTAssertThrowsError(try VaultCrypto.unwrap(file, password: "secret2")) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testUnicodePasswordIsNormalized() throws {
        let master = VaultCrypto.newMasterKey()
        let composed = "caf\u{E9}-pass"     // é as one code point
        let decomposed = "cafe\u{301}-pass" // e + combining accent
        let file = try VaultCrypto.makeKeyFile(masterKey: master, password: composed, iterations: rounds)
        XCTAssertEqual(try VaultCrypto.unwrap(file, password: decomposed).rawData, master.rawData)
    }

    func testNoteRoundTrip() throws {
        let key = VaultCrypto.newMasterKey()
        let text = "# Title\n\nUnicode ✓ 日本語 🎉\n- [ ] task"
        let sealed = try VaultCrypto.encryptNote(text, key: key)
        XCTAssertTrue(sealed.starts(with: VaultCrypto.noteMagic))
        XCTAssertNil(sealed.range(of: Data("Title".utf8)), "plaintext leaked into the file")
        XCTAssertEqual(try VaultCrypto.decryptNote(sealed, key: key), text)
    }

    func testTamperedNoteFails() throws {
        let key = VaultCrypto.newMasterKey()
        var sealed = try VaultCrypto.encryptNote("hello", key: key)
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try VaultCrypto.decryptNote(sealed, key: key))
    }

    func testOtherKeyCantReadNote() throws {
        let sealed = try VaultCrypto.encryptNote("hello", key: VaultCrypto.newMasterKey())
        XCTAssertThrowsError(try VaultCrypto.decryptNote(sealed, key: VaultCrypto.newMasterKey()))
    }

    func testRecoveryKeyFormatAndParsing() throws {
        let master = VaultCrypto.newMasterKey()
        let recovery = VaultCrypto.recoveryString(master)
        XCTAssertEqual(recovery.split(separator: "-").count, 16)
        XCTAssertEqual(recovery.count, 64 + 15)
        // Lowercase, spaces and line breaks are fine.
        let messy = recovery.lowercased().replacingOccurrences(of: "-", with: " ") + "\n"
        XCTAssertEqual(try VaultCrypto.parseRecovery(messy).rawData, master.rawData)
        XCTAssertThrowsError(try VaultCrypto.parseRecovery("ABCD-1234")) {
            XCTAssertEqual($0 as? VaultError, .badRecoveryKey)
        }
    }

    func testRecoveryKeyCheckValue() throws {
        let master = VaultCrypto.newMasterKey()
        let file = try VaultCrypto.makeKeyFile(masterKey: master, password: "secret1", iterations: rounds)
        XCTAssertTrue(VaultCrypto.matches(master, file))
        XCTAssertFalse(VaultCrypto.matches(VaultCrypto.newMasterKey(), file))
    }

    func testChangingPasswordKeepsNotesReadable() throws {
        let master = VaultCrypto.newMasterKey()
        let note = try VaultCrypto.encryptNote("still here", key: master)
        let old = try VaultCrypto.makeKeyFile(masterKey: master, password: "old-pass", iterations: rounds)
        let unwrapped = try VaultCrypto.unwrap(old, password: "old-pass")
        let new = try VaultCrypto.makeKeyFile(masterKey: unwrapped, password: "new-pass", iterations: rounds)

        XCTAssertNotEqual(old.salt, new.salt)
        XCTAssertThrowsError(try VaultCrypto.unwrap(new, password: "old-pass"))
        let reopened = try VaultCrypto.unwrap(new, password: "new-pass")
        XCTAssertEqual(try VaultCrypto.decryptNote(note, key: reopened), "still here")
    }

    func testInboxRoundTripWithoutMasterKey() throws {
        let master = VaultCrypto.newMasterKey()
        let file = try VaultCrypto.makeKeyFile(masterKey: master, password: "secret1", iterations: rounds)
        // Sealing needs only the public key (works while locked)…
        let sealed = try VaultCrypto.sealToInbox(Data("8,214 steps".utf8), publicKey: XCTUnwrap(file.inboxPublicKey))
        XCTAssertNil(sealed.range(of: Data("steps".utf8)))
        // …opening needs the master key.
        let privateKey = try VaultCrypto.inboxPrivateKey(file, master: master)
        XCTAssertEqual(String(decoding: try VaultCrypto.openInbox(sealed, privateKey: privateKey), as: UTF8.self), "8,214 steps")
        XCTAssertThrowsError(try VaultCrypto.inboxPrivateKey(file, master: VaultCrypto.newMasterKey()))
    }

    func testAssetRoundTripAndTamper() throws {
        let key = VaultCrypto.newMasterKey()
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        var sealed = try VaultCrypto.encryptAsset(bytes, key: key)
        XCTAssertEqual(try VaultCrypto.decryptAsset(sealed, key: key), bytes)
        sealed[sealed.count - 1] ^= 1
        XCTAssertThrowsError(try VaultCrypto.decryptAsset(sealed, key: key))
    }

    func testKeyFileWithoutInboxStillDecodes() throws {
        // Key files written before the inbox existed have no inbox fields.
        var file = try VaultCrypto.makeKeyFile(masterKey: VaultCrypto.newMasterKey(), password: "secret1", iterations: rounds)
        file.inboxPublicKey = nil
        file.inboxPrivateKey = nil
        let json = try KeyFileIO.encode(file)
        XCTAssertNil(String(decoding: json, as: UTF8.self).range(of: "inbox"))
        XCTAssertEqual(try KeyFileIO.decode(json), file)
    }

    func testKeyFileJSONRoundTrip() throws {
        let file = try VaultCrypto.makeKeyFile(masterKey: VaultCrypto.newMasterKey(), password: "secret1", iterations: rounds)
        let json = try KeyFileIO.encode(file)
        XCTAssertEqual(try KeyFileIO.decode(json), file)
        XCTAssertThrowsError(try KeyFileIO.decode(Data("{}".utf8))) {
            XCTAssertEqual($0 as? VaultError, .badKeyFile)
        }
    }
}
