import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3-compatible storage (AWS S3, Cloudflare R2, MinIO, …).
struct SigV4 {
    var accessKey: String
    var secretKey: String
    var region: String
    var service = "s3"

    static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static let emptyHash = sha256Hex(Data())

    /// RFC 3986 encoding as S3 expects: only A–Z a–z 0–9 - . _ ~ stay as they are.
    static func encode(_ string: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static let amzFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// Adds x-amz-date, x-amz-content-sha256 and Authorization. Signs Host and every header already set.
    func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) {
        let amzDate = Self.amzFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        guard let url = request.url, let host = url.host else { return }
        let hostValue = url.port.map { "\(host):\($0)" } ?? host

        var headers: [String: String] = ["host": hostValue]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased() != "authorization" {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")

        let path = url.path(percentEncoded: true)
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { (Self.encode($0.name), Self.encode($0.value ?? "")) }
            .sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            path.isEmpty ? "/" : path,
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            Self.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")

        func hmac(_ key: SymmetricKey, _ text: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)))
        }
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] { key = hmac(key, part) }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }
}

/// Where backups go. S3 in the app; a fake in tests and demo mode.
protocol ObjectStore {
    /// Object key → ETag (quotes removed).
    func list(prefix: String) async throws -> [String: String]
    func put(_ data: Data, key: String) async throws
    func get(key: String) async throws -> Data
}

struct S3Error: LocalizedError {
    var status: Int
    var body: String
    var errorDescription: String? {
        let code = body.range(of: "<Code>").flatMap { start in
            body.range(of: "</Code>").map { String(body[start.upperBound..<$0.lowerBound]) }
        }
        switch status {
        case 403: return String(localized: "Access denied (\(code ?? "403")). Check the access key, secret and bucket.")
        case 404: return String(localized: "Bucket not found. Check the bucket name and endpoint.")
        default: return String(localized: "Storage error \(status)\(code.map { " (\($0))" } ?? "").")
        }
    }
}

/// S3-compatible storage with path-style URLs: https://endpoint/bucket/key
struct S3Store: ObjectStore {
    var endpoint: URL
    var bucket: String
    var signer: SigV4
    var session: URLSession = .shared

    private func url(key: String?, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let keyPath = key.map { "/" + SigV4.encode($0, keepSlash: true) } ?? ""
        components.percentEncodedPath = "/\(SigV4.encode(bucket))\(keyPath)"
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(SigV4.encode($0.name))=\(SigV4.encode($0.value ?? ""))" }
                .joined(separator: "&")
        }
        return components.url!
    }

    private func send(_ request: URLRequest, body: Data = Data()) async throws -> Data {
        var request = request
        signer.sign(&request, payloadHash: SigV4.sha256Hex(body))
        let (data, response) = body.isEmpty
            ? try await session.data(for: request)
            : try await session.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw S3Error(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func list(prefix: String) async throws -> [String: String] {
        var result: [String: String] = [:]
        var token: String?
        repeat {
            var query = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: prefix)]
            if let token { query.append(URLQueryItem(name: "continuation-token", value: token)) }
            let data = try await send(URLRequest(url: url(key: nil, query: query)))
            let page = ListParser.parse(data)
            result.merge(page.objects) { $1 }
            token = page.nextToken
        } while token != nil
        return result
    }

    func put(_ data: Data, key: String) async throws {
        var request = URLRequest(url: url(key: key))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await send(request, body: data)
    }

    func get(key: String) async throws -> Data {
        try await send(URLRequest(url: url(key: key)))
    }
}

/// ListObjectsV2 XML → keys, ETags, continuation token.
final class ListParser: NSObject, XMLParserDelegate {
    private(set) var objects: [String: String] = [:]
    private(set) var nextToken: String?
    private var key = "", etag = "", text = ""

    static func parse(_ data: Data) -> (objects: [String: String], nextToken: String?) {
        let delegate = ListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.objects, delegate.nextToken)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "Key": key = text
        case "ETag": etag = text.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "&quot;", with: "")
        case "Contents": objects[key] = etag
        case "NextContinuationToken": nextToken = text.isEmpty ? nil : text
        default: break
        }
    }
}
