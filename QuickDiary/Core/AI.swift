import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Who answers AI requests. Nothing is sent anywhere until the user taps an AI action.
enum AIProvider: String, CaseIterable, Identifiable {
    case off, onDevice, server
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .onDevice: String(localized: "On device")
        case .server: String(localized: "Your server")
        }
    }
}

protocol AIEngine {
    /// Where the text goes, shown next to every AI button: "On this device" or the server host.
    var destination: String { get }
    var supportsImages: Bool { get }
    func complete(instructions: String, prompt: String, images: [Data]) async throws -> String
}

struct AIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Prompts used by the app, in one place.
enum AIPrompts {
    static let summarizeNote = """
        You summarize personal diary notes. Reply in the language of the note, in 2 to 4 short sentences, \
        first person, plain words. No preamble, no headings.
        """
    static let suggestTitle = """
        Suggest a title for this diary note: at most 6 words, in the language of the note. \
        Reply with the title only, no quotes.
        """
    static let summarizeDay = """
        Write a short diary summary of this day in 3 to 5 sentences, first person, plain words. \
        Use only the facts given; do not invent anything. No preamble.
        """
}

// MARK: OpenAI-compatible server (OpenAI, OpenRouter, Ollama, llama.cpp, vLLM, …)

struct OpenAICompatibleEngine: AIEngine {
    var baseURL: URL
    var apiKey: String
    var model: String
    var session: URLSession = .shared

    var destination: String { baseURL.host ?? baseURL.absoluteString }
    var supportsImages: Bool { true }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        return request
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = String(decoding: data.prefix(200), as: UTF8.self)
            throw AIError(message: String(localized: "\(destination) answered \(status). \(detail)"))
        }
    }

    func models() async throws -> [String] {
        let (data, response) = try await session.data(for: request("models"))
        try check(response, data)
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }

    func complete(instructions: String, prompt: String, images: [Data]) async throws -> String {
        var userContent: Any = prompt
        if !images.isEmpty {
            var parts: [[String: Any]] = [["type": "text", "text": prompt]]
            for image in images {
                parts.append(["type": "image_url",
                              "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]])
            }
            userContent = parts
        }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": userContent],
            ],
        ]
        var request = request("chat/completions")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let text = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Apple on-device model (iOS 26, Apple Intelligence devices)

enum AppleOnDevice {
    /// nil when it can be used; otherwise why not.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return String(localized: "Turn on Apple Intelligence in the Settings app.")
            case .unavailable(.modelNotReady):
                return String(localized: "The on-device model is still downloading. Try again later.")
            default:
                return String(localized: "This device doesn't support Apple Intelligence.")
            }
        }
        #endif
        return String(localized: "Needs iOS 26 and a device with Apple Intelligence.")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct AppleOnDeviceEngine: AIEngine {
    var destination: String { String(localized: "On this device") }
    var supportsImages: Bool { false }

    func complete(instructions: String, prompt: String, images: [Data]) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

/// Demo mode and UI tests: fixed answers, no network.
struct DemoAIEngine: AIEngine {
    var destination: String { String(localized: "Demo (nothing is sent)") }
    var supportsImages: Bool { true }

    func complete(instructions: String, prompt: String, images: [Data]) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        if instructions == AIPrompts.suggestTitle { return "A light morning run" }
        if instructions == AIPrompts.summarizeDay {
            return "I finished two errands, had standup and yoga, and the weather stayed mild. A calm, productive day."
        }
        return "I ran the riverside loop in cool air and set a new best on the hill. I still need to log my shoe mileage."
    }
}

/// Settings › AI. The API key is kept in the Keychain.
@MainActor
final class AISettings: ObservableObject {
    @Published var provider: AIProvider { didSet { defaults.set(provider.rawValue, forKey: "aiProvider") } }
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "aiServerURL") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "aiModel") } }
    @Published var apiKey: String { didSet { Secrets.set(apiKey, for: Secrets.aiKey) } }

    private let defaults = UserDefaults.standard
    let demo: Bool

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("-demo")) {
        self.demo = demo
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? (demo ? .server : .off)
        serverURL = UserDefaults.standard.string(forKey: "aiServerURL") ?? ""
        model = UserDefaults.standard.string(forKey: "aiModel") ?? ""
        apiKey = Secrets.get(Secrets.aiKey) ?? ""
    }

    var serverEngine: OpenAICompatibleEngine? {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)), url.host != nil,
              !model.isEmpty else { return nil }
        return OpenAICompatibleEngine(baseURL: url, apiKey: apiKey, model: model)
    }

    /// The engine to use now, or nil when AI is off or not set up.
    var engine: AIEngine? {
        if demo { return DemoAIEngine() }
        switch provider {
        case .off: return nil
        case .server: return serverEngine
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), AppleOnDevice.unavailableReason == nil { return AppleOnDeviceEngine() }
            #endif
            return nil
        }
    }

    /// Why AI buttons are disabled, in one line.
    var disabledReason: String? {
        if engine != nil { return nil }
        switch provider {
        case .off: return String(localized: "Turn on AI in Settings › AI.")
        case .onDevice: return AppleOnDevice.unavailableReason
        case .server: return String(localized: "Add the server address and model in Settings › AI.")
        }
    }

    /// Photos for AI: small JPEGs, only the ones the user picked.
    static func jpegForAI(_ image: UIImage) -> Data? { AssetStore.prepare(image, maxSide: 768) }
}
