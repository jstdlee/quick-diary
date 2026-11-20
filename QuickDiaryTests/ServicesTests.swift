import XCTest
@testable import QuickDiary

/// Fake HTTP server for tests: no network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                              httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SigV4Tests: XCTestCase {
    /// AWS documentation examples (Signature Version 4, "GET Object" and "List Objects").
    private let signer = SigV4(accessKey: "AKIAIOSFODNN7EXAMPLE",
                               secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                               region: "us-east-1")
    private let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    func testGetObjectExample() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        signer.sign(&request, payloadHash: SigV4.emptyHash, date: date)
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.contains("Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"))
        XCTAssertTrue(auth.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"), auth)
    }

    func testListObjectsExample() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!)
        signer.sign(&request, payloadHash: SigV4.emptyHash, date: date)
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"), auth)
    }

    func testEncoding() {
        XCTAssertEqual(SigV4.encode("Quick Diary/a+b.md.enc", keepSlash: true), "Quick%20Diary/a%2Bb.md.enc")
        XCTAssertEqual(SigV4.encode("a/b"), "a%2Fb")
    }

    func testListParser() {
        let xml = """
        <ListBucketResult><IsTruncated>true</IsTruncated>
        <Contents><Key>quick-diary/a.md.enc</Key><ETag>&quot;abc123&quot;</ETag></Contents>
        <Contents><Key>quick-diary/assets/b.jpg.enc</Key><ETag>"def456"</ETag></Contents>
        <NextContinuationToken>tok</NextContinuationToken></ListBucketResult>
        """
        let page = ListParser.parse(Data(xml.utf8))
        XCTAssertEqual(page.objects, ["quick-diary/a.md.enc": "abc123", "quick-diary/assets/b.jpg.enc": "def456"])
        XCTAssertEqual(page.nextToken, "tok")
    }

    func testS3StoreUsesPathStyleAndSigns() async throws {
        StubProtocol.requests = []
        StubProtocol.handler = { _, _ in (200, Data()) }
        let store = S3Store(endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")!, bucket: "diary",
                            signer: SigV4(accessKey: "AK", secretKey: "SK", region: "auto"),
                            session: StubProtocol.session())
        try await store.put(Data("x".utf8), key: "quick-diary/2026-10-03_1432.md.enc")
        let (request, body) = try XCTUnwrap(StubProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://acct.r2.cloudflarestorage.com/diary/quick-diary/2026-10-03_1432.md.enc")
        XCTAssertEqual(body, Data("x".utf8))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/") == true)
    }
}

final class BackupTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("key".utf8).write(to: folder.appendingPathComponent("quick-diary-key.json"))
        try Data("note".utf8).write(to: folder.appendingPathComponent("2026-10-03_1432.md.enc"))
        try Data("photo".utf8).write(to: folder.appendingPathComponent("assets/2026-10-03_1432-1.jpg.enc"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testBackUpOnlyUploadsChanges() async throws {
        let store = MemoryStore()
        var summary = try await BackupEngine.backUp(folder: folder, to: store, prefix: "quick-diary")
        XCTAssertEqual(summary.uploaded, 3)
        XCTAssertEqual(Set(store.objects.keys), ["quick-diary/quick-diary-key.json",
                                                 "quick-diary/2026-10-03_1432.md.enc",
                                                 "quick-diary/assets/2026-10-03_1432-1.jpg.enc"])
        summary = try await BackupEngine.backUp(folder: folder, to: store, prefix: "quick-diary")
        XCTAssertEqual(summary, BackupEngine.Summary(uploaded: 0, unchanged: 3, bytes: 0))

        try Data("note v2".utf8).write(to: folder.appendingPathComponent("2026-10-03_1432.md.enc"))
        summary = try await BackupEngine.backUp(folder: folder, to: store, prefix: "quick-diary")
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.unchanged, 2)
    }

    func testRestoreMissingNeverReplaces() async throws {
        let store = MemoryStore()
        _ = try await BackupEngine.backUp(folder: folder, to: store, prefix: "p")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        try Data("local wins".utf8).write(to: target.appendingPathComponent("2026-10-03_1432.md.enc"))

        let restored = try await BackupEngine.restoreMissing(folder: target, from: store, prefix: "p")
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("2026-10-03_1432.md.enc")), Data("local wins".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("assets/2026-10-03_1432-1.jpg.enc")), Data("photo".utf8))
    }

    func testExportZip() throws {
        let zip = try BackupEngine.exportZip(folder: folder)
        let header = try Data(contentsOf: zip).prefix(2)
        XCTAssertEqual(header, Data("PK".utf8))
    }

    /// A store that refuses every upload. The next destination must still receive the files.
    func testOneDestinationFailingDoesNotStopTheNext() async {
        let good = MemoryStore()
        let runs = await BackupEngine.backUp(folder: folder, destinations: [
            ("bad", BoomStore(), "p"),
            ("good", good, "p"),
        ])
        XCTAssertEqual(runs.map(\.name), ["bad", "good"])
        XCTAssertEqual(runs[0].error, "nope")
        XCTAssertNil(runs[0].summary)
        XCTAssertEqual(runs[1].summary?.uploaded, 3)
        XCTAssertEqual(good.objects.count, 3)
    }

    func testRestoreReadsOnlyTheChosenStore() async throws {
        let chosen = MemoryStore()
        let other = MemoryStore()
        _ = try await BackupEngine.backUp(folder: folder, to: chosen, prefix: "p")
        try await other.put(Data("only-other".utf8), key: "p/only-other.enc")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("RestoreOne-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let restored = try await BackupEngine.restoreMissing(folder: target, from: chosen, prefix: "p")
        XCTAssertEqual(restored, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("only-other.enc").path))
    }

    func testS3FingerprintIsTheSinglePartETag() {
        let store = S3Store(endpoint: URL(string: "https://example.com")!, bucket: "b",
                            signer: SigV4(accessKey: "a", secretKey: "s", region: "auto"))
        XCTAssertEqual(store.fingerprint(Data("hello".utf8)), "5d41402abc4b2a76b9719d911017c592")
    }

    func testOldS3ConfigBecomesTheFirstDestination() throws {
        let suite = "DestinationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = BackupConfig(endpoint: "https://acct.r2.cloudflarestorage.com", region: "auto",
                                   bucket: "diary", prefix: "notes", accessKeyID: "AKIA")
        defaults.set(try JSONEncoder().encode(config), forKey: BackupConfig.storageKey)
        var box = [Secrets.s3Secret: "sekrit"]
        let loaded = DestinationLibrary.load(defaults: defaults, getSecret: { box[$0] }, setSecret: { value, account in
            if value.isEmpty { box.removeValue(forKey: account) } else { box[account] = value }
        })
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].kind, .s3)
        XCTAssertEqual(loaded[0].name, "diary")
        XCTAssertTrue(loaded[0].enabled)
        XCTAssertEqual(loaded[0].endpoint, "https://acct.r2.cloudflarestorage.com")
        XCTAssertEqual(loaded[0].region, "auto")
        XCTAssertEqual(loaded[0].bucket, "diary")
        XCTAssertEqual(loaded[0].prefix, "notes")
        XCTAssertEqual(loaded[0].accessKeyID, "AKIA")
        XCTAssertNil(box[Secrets.s3Secret])
        XCTAssertEqual(box[DestinationLibrary.secretAccount(loaded[0].id)], "sekrit")
        XCTAssertNil(defaults.data(forKey: BackupConfig.storageKey))
        let again = DestinationLibrary.load(defaults: defaults, getSecret: { box[$0] }, setSecret: { _, _ in
            XCTFail("loading a saved list must not write secrets again")
        })
        XCTAssertEqual(again, loaded)
    }
}

private final class BoomStore: ObjectStore {
    func list(prefix: String) async throws -> [String: String] { [:] }
    func fingerprint(_ data: Data) -> String { ContentHash.md5Hex(data) }
    func put(_ data: Data, key: String) async throws { throw GitHubFailure(message: "nope") }
    func get(key: String) async throws -> Data { Data() }
}

final class GitHubBackupTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("GitHubBackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("note.enc"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// git blob id of the bytes "hello", computed outside the app.
    private let helloBlob = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"

    func testFingerprintIsTheGitBlobId() {
        let store = GitHubStore(owner: "ada", repo: "diary", branch: "main", token: "t")
        XCTAssertEqual(store.fingerprint(Data("hello".utf8)), helloBlob)
    }

    func testUnchangedFileIsNotUploaded() async throws {
        script(tree: [["path": "quick-diary/note.enc", "sha": helloBlob]])
        let summary = try await BackupEngine.backUp(folder: folder, to: makeStore(), prefix: "quick-diary")
        XCTAssertEqual(summary.uploaded, 0)
        XCTAssertEqual(summary.unchanged, 1)
        XCTAssertFalse(StubProtocol.requests.contains { $0.0.httpMethod == "POST" || $0.0.httpMethod == "PATCH" })
    }

    func testChangedFileIsOneCommit() async throws {
        script(tree: [])
        let summary = try await BackupEngine.backUp(folder: folder, to: makeStore(), prefix: "quick-diary")
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.skipped, 0)
        let posts = StubProtocol.requests.filter { $0.0.httpMethod == "POST" }.map { $0.0.url?.path }
        XCTAssertEqual(posts, [
            "/repos/ada/diary/git/blobs",
            "/repos/ada/diary/git/trees",
            "/repos/ada/diary/git/commits",
        ])
        let blob = body(where: { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/git/blobs") == true })
        XCTAssertTrue(blob.contains("aGVsbG8="), blob)
        let tree = body(where: { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/git/trees") == true })
        XCTAssertTrue(tree.contains("quick-diary/note.enc"), tree)
        XCTAssertTrue(tree.contains("BLOBNEW"), tree)
        let commit = body(where: { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/git/commits") == true })
        XCTAssertTrue(commit.contains("Backup Quick Diary"), commit)
        XCTAssertTrue(commit.contains("COMMIT1"), commit)
        let patch = StubProtocol.requests.filter { $0.0.httpMethod == "PATCH" }
        XCTAssertEqual(patch.count, 1)
        XCTAssertTrue(String(decoding: patch[0].1, as: UTF8.self).contains("COMMIT2"))
    }

    func testPublicRepoIsRefusedBeforeAnyUpload() async {
        script(tree: [], isPrivate: false)
        do {
            _ = try await BackupEngine.backUp(folder: folder, to: makeStore(), prefix: "quick-diary")
            XCTFail("a public repo must be refused")
        } catch {
            XCTAssertEqual(error as? GitHubFailure, GitHubFailure.publicRepo)
        }
        XCTAssertFalse(StubProtocol.requests.contains { $0.0.url?.path.contains("/git/") == true })
    }

    func testFileAtTheSizeLimitIsLeftOutOfTheCommit() async throws {
        try Data("ok".utf8).write(to: folder.appendingPathComponent("ok.enc"))
        script(tree: [])
        let summary = try await BackupEngine.backUp(folder: folder, to: makeStore(maxBytes: 5), prefix: "quick-diary")
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.uploaded, 1)
        let tree = body(where: { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/git/trees") == true })
        XCTAssertTrue(tree.contains("quick-diary/ok.enc"), tree)
        XCTAssertFalse(tree.contains("note.enc"), tree)
    }

    private func makeStore(maxBytes: Int = 95_000_000) -> GitHubStore {
        let store = GitHubStore(owner: "ada", repo: "diary", branch: "main", token: "ghs_test",
                                session: StubProtocol.session())
        store.maxBytes = maxBytes
        return store
    }

    private func body(where predicate: (URLRequest) -> Bool) -> String {
        let match = StubProtocol.requests.first { predicate($0.0) }
        return String(decoding: match?.1 ?? Data(), as: UTF8.self)
    }

    private func script(tree: [[String: String]], isPrivate: Bool = true) {
        StubProtocol.requests = []
        StubProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            if method == "GET", path == "/repos/ada/diary" {
                let flag = isPrivate ? "true" : "false"
                return (200, Data(#"{"private":\#(flag),"default_branch":"main"}"#.utf8))
            }
            if method == "GET", path == "/repos/ada/diary/git/ref/heads/main" {
                return (200, Data(#"{"object":{"sha":"COMMIT1"}}"#.utf8))
            }
            if method == "GET", path == "/repos/ada/diary/git/commits/COMMIT1" {
                return (200, Data(#"{"tree":{"sha":"TREE1"}}"#.utf8))
            }
            if method == "GET", path.hasPrefix("/repos/ada/diary/git/trees/TREE1") {
                let entries = tree.map { #"{"path":"\#($0["path"]!)","type":"blob","sha":"\#($0["sha"]!)"}"# }
                    .joined(separator: ",")
                return (200, Data(#"{"tree":[\#(entries)],"truncated":false}"#.utf8))
            }
            if method == "POST", path == "/repos/ada/diary/git/blobs" {
                return (201, Data(#"{"sha":"BLOBNEW"}"#.utf8))
            }
            if method == "POST", path == "/repos/ada/diary/git/trees" {
                return (201, Data(#"{"sha":"TREE2"}"#.utf8))
            }
            if method == "POST", path == "/repos/ada/diary/git/commits" {
                return (201, Data(#"{"sha":"COMMIT2"}"#.utf8))
            }
            if method == "PATCH", path == "/repos/ada/diary/git/refs/heads/main" {
                return (200, Data(#"{"ref":"refs/heads/main"}"#.utf8))
            }
            return (500, Data("unexpected \(method) \(path)".utf8))
        }
    }
}

final class AITests: XCTestCase {
    func testChatCompletionRequestAndReply() async throws {
        StubProtocol.requests = []
        StubProtocol.handler = { _, _ in
            (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"  A calm day.  "}}]}"#.utf8))
        }
        let engine = OpenAICompatibleEngine(baseURL: URL(string: "http://127.0.0.1:8888/v1")!, apiKey: "sk-test",
                                            model: "qwen", session: StubProtocol.session())
        let reply = try await engine.complete(instructions: "Summarize.", prompt: "Ran 5 km.", images: [Data([1, 2])])
        XCTAssertEqual(reply, "A calm day.")
        let (request, body) = try XCTUnwrap(StubProtocol.requests.last)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8888/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "Summarize.")
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue((parts[1]["image_url"] as? [String: String])?["url"]?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    func testModelsAndErrors() async throws {
        StubProtocol.handler = { request, _ in
            request.url!.path.hasSuffix("/models")
                ? (200, Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8))
                : (401, Data("bad key".utf8))
        }
        let engine = OpenAICompatibleEngine(baseURL: URL(string: "https://api.example.com/v1")!, apiKey: "",
                                            model: "a", session: StubProtocol.session())
        let models = try await engine.models()
        XCTAssertEqual(models, ["a", "b"])
        do {
            _ = try await engine.complete(instructions: "x", prompt: "y", images: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
        }
    }
}
