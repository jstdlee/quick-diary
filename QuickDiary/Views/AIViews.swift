import SwiftUI

/// One AI request, shown with its result before anything is inserted.
struct AIRequest: Identifiable {
    let id = UUID()
    var title: String
    var engine: AIEngine
    var instructions: String
    var prompt: String
    var images: [Data] = []
}

/// Runs the request, shows the answer, and inserts it only when the user taps Insert.
struct AIResultSheet: View {
    let request: AIRequest
    var insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(sentLine, systemImage: request.engine.destination == String(localized: "On this device")
                          ? "iphone" : "network")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let result {
                        Text(result)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("aiResult")
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Writing…").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        if let result { insert(result) }
                        dismiss()
                    }
                    .disabled(result == nil)
                    .accessibilityIdentifier("aiInsert")
                }
            }
            .task { await run() }
        }
        .presentationDetents([.medium, .large])
    }

    private var sentLine: String {
        let what = request.images.isEmpty
            ? String(localized: "\(request.prompt.count) characters")
            : String(localized: "\(request.prompt.count) characters and \(request.images.count) photos")
        return String(localized: "\(what) · \(request.engine.destination)")
    }

    private func run() async {
        do {
            let text = try await request.engine.complete(instructions: request.instructions,
                                                         prompt: request.prompt, images: request.images)
            result = text.isEmpty ? String(localized: "(No answer)") : text
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Settings › AI.
struct AISettingsView: View {
    @EnvironmentObject private var ai: AISettings
    @State private var testState: String?
    @State private var testing = false
    @State private var models: [String] = []

    var body: some View {
        Form {
            Section {
                Picker("AI", selection: $ai.provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("aiProvider")
            } footer: {
                Text("AI writes summaries and titles when you tap ✨. You see every answer before it goes into a note.")
            }

            switch ai.provider {
            case .off:
                EmptyView()
            case .onDevice:
                Section {
                    if let reason = AppleOnDevice.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    } else {
                        Label("Ready. Nothing leaves this device.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Apple on-device model")
                }
            case .server:
                serverSection
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var serverSection: some View {
        Section {
            TextField("https://api.openai.com/v1", text: $ai.serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("aiServerURL")
            SecureField("API key (optional for local servers)", text: $ai.apiKey)
            if models.isEmpty {
                TextField("Model, e.g. gpt-4o-mini", text: $ai.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                Picker("Model", selection: $ai.model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            Button(action: test) {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || URL(string: ai.serverURL)?.host == nil)
            if let testState {
                Text(testState).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("OpenAI-compatible server")
        } footer: {
            Text("Works with OpenAI, OpenRouter, Ollama, llama.cpp, vLLM and others. Only the note or the facts and photos you pick are sent, each time you tap. The key is kept in this iPhone's Keychain.")
        }
    }

    private func test() {
        guard let url = URL(string: ai.serverURL.trimmingCharacters(in: .whitespaces)) else { return }
        testing = true
        testState = nil
        Task {
            defer { testing = false }
            do {
                let found = try await OpenAICompatibleEngine(baseURL: url, apiKey: ai.apiKey, model: ai.model).models()
                models = found
                if ai.model.isEmpty || !found.contains(ai.model) { ai.model = found.first ?? ai.model }
                testState = String(localized: "Connected · \(found.count) models")
            } catch {
                testState = error.localizedDescription
            }
        }
    }
}
