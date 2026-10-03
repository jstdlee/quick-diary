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
