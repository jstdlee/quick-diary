import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case let .folderProblem(message):
            FolderProblemView(message: message)
        case .setup:
            SetupView()
        case .missingKey:
            MissingKeyView()
        case .locked:
            UnlockView()
        case .unlocked:
            NotesListView()
        }
    }
}

/// A recovery key to show in a sheet.
struct ShownRecoveryKey: Identifiable {
    let id = UUID()
    let key: String
}

// MARK: - First run

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false
    @State private var recovery: ShownRecoveryKey?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Notes are encrypted on this device before they are saved. Only your password or your recovery key opens them.")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "lock.doc").foregroundStyle(.tint)
                    }
                }
                Section {
                    SecureField("Password", text: $password)
                        .accessibilityIdentifier("password")
                    SecureField("Repeat password", text: $confirm)
                        .accessibilityIdentifier("confirm")
                        .onSubmit(create)
                } header: {
                    Text("Create a password")
                } footer: {
                    Text("At least 6 characters. Nobody can reset it for you.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button(action: create) {
                        HStack {
                            Text("Create vault")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || password.isEmpty)
                    .accessibilityIdentifier("create")
                }
                Section {
                    LabeledContent("Saved in", value: model.folderDisplay)
                } footer: {
                    Text("You can change this later in Settings.")
                }
            }
            .navigationTitle("Quick Diary")
        }
        .sheet(item: $recovery) { shown in
            RecoveryKeySheet(key: shown.key) { model.finishSetup() }
        }
    }

    private func create() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                recovery = ShownRecoveryKey(key: try await model.createVault(password: password, confirm: confirm))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct RecoveryKeySheet: View {
    let key: String
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("If you forget your password, this key is the only way to open your notes. Save it somewhere safe, apart from this phone — a password manager or on paper.")
                        .foregroundStyle(.secondary)
                    RecoveryKeyCard(key: key)
                }
                .padding()
            }
            .navigationTitle("Recovery key")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(action: onDone) {
                    Text("I saved my recovery key").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .accessibilityIdentifier("savedRecoveryKey")
            }
        }
        .interactiveDismissDisabled()
    }
}

struct RecoveryKeyCard: View {
    let key: String
    @State private var copied = false

    private var rows: [String] {
        let groups = key.split(separator: "-").map(String.init)
        guard groups.count == 16 else { return [key] }
        return stride(from: 0, to: 16, by: 4).map { groups[$0..<$0 + 4].joined(separator: "  ") }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                ForEach(rows, id: \.self) { Text($0) }
            }
            .font(.system(.title3, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("recoveryKeyText")

            HStack {
                Button {
                    UIPasteboard.general.string = key
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
                ShareLink(item: key) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Unlock

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var error: String?
    @State private var working = false
    @State private var showRestore = false
    @State private var failures = 0
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 44

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Quick Diary").font(.largeTitle.bold())
                Text(model.folderDisplay).font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused)
                    .onSubmit(unlock)
                    .padding(12)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("unlockPassword")
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("unlockError")
                }
                Button(action: unlock) {
                    HStack {
                        if working { ProgressView().tint(.white) }
                        Text("Unlock")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working || password.isEmpty)
                .accessibilityIdentifier("unlock")
            }
            .frame(maxWidth: 420)
            Button("Forgot password?") { showRestore = true }
                .font(.footnote)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .sensoryFeedback(.error, trigger: failures)
        .onAppear { focused = true }
        .sheet(isPresented: $showRestore) { RestoreView() }
    }

    private func unlock() {
        guard !working, !password.isEmpty else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.unlock(password: password)
            } catch {
                self.error = error.localizedDescription
                failures += 1
                password = ""
            }
        }
    }
}

/// Set a new password with the recovery key (forgotten password or lost key file).
struct RestoreView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var recovery = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-…", text: $recovery, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Recovery key")
                } footer: {
                    Text("Spaces and dashes don't matter.")
                }
                Section("New password") {
                    SecureField("New password", text: $password)
                    SecureField("Repeat new password", text: $confirm)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button(action: restore) {
                        HStack {
                            Text("Set new password")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || recovery.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Use recovery key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func restore() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.restore(recovery: recovery, newPassword: password, confirm: confirm)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The folder has notes but no key file.
struct MissingKeyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showRestore = false
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This folder has encrypted notes but no key file (quick-diary-key.json). Put the key file back, or use your recovery key to set a new password.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button { importing = true } label: {
                        Label("Import key file…", systemImage: "key")
                    }
                    Button { showRestore = true } label: {
                        Label("Use recovery key", systemImage: "key.viewfinder")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    LabeledContent("Folder", value: model.folderDisplay)
                }
            }
            .navigationTitle("Key file missing")
        }
        .sheet(isPresented: $showRestore) { RestoreView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            do {
                try model.importKeyFile(from: result.get())
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct FolderProblemView: View {
    @EnvironmentObject private var model: AppModel
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Can't open notes", systemImage: "folder.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await model.retry() } }
                .buttonStyle(.borderedProminent)
            Button("Use this iPhone instead") { Task { await model.useLocalStorage() } }
        }
    }
}
