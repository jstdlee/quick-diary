import CryptoKit
import Foundation

struct GitHubFailure: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }

    static let publicRepo = GitHubFailure(message: "This repo is public. Quick Diary will not upload to it.")
    static let missingBranch = GitHubFailure(message: "Create the repo and the branch on GitHub first.")

    static func http(_ status: Int, path: String, body: String) -> GitHubFailure {
        switch status {
        case 401, 403:
            return GitHubFailure(message: "Access denied. Check the token, and that the repo is private.")
        case 404 where path.contains("/git/ref/"):
            return .missingBranch
        case 404:
            return GitHubFailure(message: "Repo not found. Check the owner, repo and token.")
        default:
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitHubFailure(message: detail.isEmpty ? "GitHub error \(status)." : "GitHub error \(status). \(detail)")
        }
    }
}

/// A private github.com repo. One successful backup is one commit. Files are the same ciphertext as the vault.
final class GitHubStore: ObjectStore {
    var owner: String
    var repo: String
    var branch: String
    var token: String
    var session: URLSession
    /// Files this size or larger are not committed. GitHub refuses a blob around 100 MB.
    var maxBytes = 95_000_000

    private var activeBranch: String?
    private var parentSHA: String?
    private var treeSHA: String?
    private var pending: [(path: String, sha: String)] = []

    init(owner: String, repo: String, branch: String, token: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.token = token
        self.session = session
    }

    func fingerprint(_ data: Data) -> String {
        var payload = Data("blob \(data.count)\0".utf8)
        payload.append(data)
        return Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    func skipReason(for data: Data) -> String? {
        data.count >= maxBytes ? "too large for GitHub" : nil
    }

    func list(prefix: String) async throws -> [String: String] {
        let meta = try await repoMeta()
        guard meta.isPrivate else { throw GitHubFailure.publicRepo }
        let branch = self.branch.trimmingCharacters(in: .whitespaces).isEmpty ? meta.defaultBranch : self.branch
        activeBranch = branch
        let ref = try await send("GET", refPath(branch), missingIsBranch: true)
        let refObject = try JSONDecoder().decode(RefBody.self, from: ref)
        parentSHA = refObject.object.sha
        let commit = try await send("GET", "\(root)/git/commits/\(refObject.object.sha)")
        let commitObject = try JSONDecoder().decode(CommitBody.self, from: commit)
        treeSHA = commitObject.tree.sha
        let tree = try await send("GET", "\(root)/git/trees/\(commitObject.tree.sha)",
                                  query: [URLQueryItem(name: "recursive", value: "1")])
        let listing = try JSONDecoder().decode(TreeBody.self, from: tree)
        if listing.truncated == true {
            throw GitHubFailure(message: "This repo has too many files to list. Use a repo that holds only this backup.")
        }
        var result: [String: String] = [:]
        for entry in listing.tree where entry.type == "blob" && entry.path.hasPrefix(prefix) {
            result[entry.path] = entry.sha
        }
        return result
    }

    func put(_ data: Data, key: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["content": data.base64EncodedString(), "encoding": "base64"])
        let response = try await send("POST", "\(root)/git/blobs", body: body)
        let blob = try JSONDecoder().decode(SHABody.self, from: response)
        pending.removeAll { $0.path == key }
        pending.append((key, blob.sha))
    }

    func finish() async throws {
        guard !pending.isEmpty else { return }
        guard let parentSHA, let treeSHA, let branch = activeBranch else {
            throw GitHubFailure(message: "GitHub error. The repo was not listed before the upload.")
        }
        let entries = pending.map { ["path": $0.path, "mode": "100644", "type": "blob", "sha": $0.sha] }
        let treeBody = try JSONSerialization.data(withJSONObject: ["base_tree": treeSHA, "tree": entries])
        let tree = try JSONDecoder().decode(SHABody.self, from: try await send("POST", "\(root)/git/trees", body: treeBody))
        let commitBody = try JSONSerialization.data(withJSONObject: [
            "message": "Backup Quick Diary", "tree": tree.sha, "parents": [parentSHA],
        ])
        let commit = try JSONDecoder().decode(SHABody.self, from: try await send("POST", "\(root)/git/commits", body: commitBody))
        _ = try await send("PATCH", refPath(branch), body: try JSONSerialization.data(withJSONObject: ["sha": commit.sha]))
        self.parentSHA = commit.sha
        self.treeSHA = tree.sha
        pending = []
    }

    func get(key: String) async throws -> Data {
        if activeBranch == nil { _ = try await repoMeta() }
        let branch = activeBranch ?? self.branch
        let encoded = key.split(separator: "/").map { SigV4.encode(String($0)) }.joined(separator: "/")
        let response = try await send("GET", "\(root)/contents/\(encoded)", query: [URLQueryItem(name: "ref", value: branch)])
        let file = try JSONDecoder().decode(ContentsBody.self, from: response)
        if file.encoding == "base64", let content = file.content,
           let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) {
            return data
        }
        let blob = try await send("GET", "\(root)/git/blobs/\(file.sha)")
        let raw = try JSONDecoder().decode(ContentsBody.self, from: blob)
        guard let content = raw.content,
              let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else {
            throw GitHubFailure(message: "GitHub returned a file that could not be read.")
        }
        return data
    }

    // MARK: Requests

    private var root: String { "/repos/\(SigV4.encode(owner))/\(SigV4.encode(repo))" }

    private func refPath(_ branch: String) -> String {
        let encoded = branch.split(separator: "/").map { SigV4.encode(String($0)) }.joined(separator: "/")
        return "\(root)/git/ref/heads/\(encoded)"
    }

    private func repoMeta() async throws -> RepoBody {
        let data = try await send("GET", root)
        return try JSONDecoder().decode(RepoBody.self, from: data)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      missingIsBranch: Bool = false) async throws -> Data {
        var components = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QuickDiary", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            (data, response) = try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 404, missingIsBranch { throw GitHubFailure.missingBranch }
            throw GitHubFailure.http(status, path: path, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

private struct RepoBody: Decodable {
    var isPrivate: Bool
    var defaultBranch: String
    enum CodingKeys: String, CodingKey {
        case isPrivate = "private"
        case defaultBranch = "default_branch"
    }
}

private struct RefBody: Decodable {
    struct Object: Decodable { var sha: String }
    var object: Object
}

private struct CommitBody: Decodable {
    struct Tree: Decodable { var sha: String }
    var tree: Tree
}

private struct TreeBody: Decodable {
    struct Entry: Decodable {
        var path: String
        var type: String
        var sha: String
    }
    var tree: [Entry]
    var truncated: Bool?
}

private struct SHABody: Decodable { var sha: String }

private struct ContentsBody: Decodable {
    var content: String?
    var encoding: String?
    var sha: String
}
