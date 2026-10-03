import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickingFolder = false
    @State private var plan: StoragePlan?
    @State private var storageError: String?
    @State private var backupURL: URL?
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                storageSection
                securitySection
                helpSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case let .success(url): preparePlan(.folder, picked: url)
                case let .failure(error): storageError = error.localizedDescription
                }
            }
            .confirmationDialog(planTitle, isPresented: planShown, titleVisibility: .visible, presenting: plan) { plan in
                Button(plan.hasVault ? String(localized: "Switch and unlock") : String(localized: "Copy notes and switch")) { apply(plan) }
                Button("Cancel", role: .cancel) {}
            } message: { plan in
                Text(planMessage(plan))
            }
            .task { backupURL = try? model.keyBackupURL() }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier("appearancePicker")
        } header: {
            Text("Appearance")
        }
        .sensoryFeedback(.selection, trigger: appearance)
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            Picker("Location", selection: storageSelection) {
                ForEach(StorageKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .accessibilityIdentifier("storagePicker")
            LabeledContent("Folder") {
                Text(model.folderDisplay)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if model.storage == .folder {
                Button("Choose another folder…") { pickingFolder = true }
            }
            if model.copying {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Copying notes…").foregroundStyle(.secondary)
                }
            }
            if let storageError {
                Label(storageError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Folder… works with any folder in Files, including shared iCloud Drive folders. Notes are copied to the new place, never moved or deleted.")
        }
    }

    /// Picking a location asks first; nothing changes until the user confirms.
    private var storageSelection: Binding<StorageKind> {
        Binding(
            get: { model.storage },
            set: { kind in
                storageError = nil
                if kind == .folder {
                    pickingFolder = true
                } else if kind != model.storage {
                    preparePlan(kind, picked: nil)
                }
            })
    }

    private func preparePlan(_ kind: StorageKind, picked: URL?) {
        Task {
            do {
                plan = try await model.plan(for: kind, picked: picked)
            } catch {
                storageError = error.localizedDescription
            }
        }
    }

    private var planShown: Binding<Bool> {
        Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })
    }

    private var planTitle: String {
        guard let plan else { return "" }
        return String(localized: "Use \(plan.kind == .folder ? plan.folder.lastPathComponent : plan.kind.title)?")
    }

    private func planMessage(_ plan: StoragePlan) -> String {
        if plan.hasVault {
            return String(localized: "This folder already has a Quick Diary vault. Quick Diary will lock; unlock it with that vault's password.")
        }
        return String(localized: "\(plan.notesToCopy) notes and the key file will be copied there. The originals stay where they are.")
    }

    private func apply(_ plan: StoragePlan) {
        Task {
            do {
                try await model.apply(plan)
                backupURL = try? model.keyBackupURL()
            } catch {
                storageError = error.localizedDescription
            }
        }
    }

    // MARK: Security

    private var securitySection: some View {
        Section {
            NavigationLink {
                ChangePasswordView()
            } label: {
                Label("Change password", systemImage: "key")
            }
            .accessibilityIdentifier("changePassword")
            NavigationLink {
                RevealRecoveryKeyView()
            } label: {
                Label("Show recovery key", systemImage: "key.viewfinder")
            }
            .accessibilityIdentifier("recoveryKey")
            if let backupURL {
                ShareLink(item: backupURL) {
                    Label("Back up key file", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                dismiss()
                model.lock()
            } label: {
                Label("Lock now", systemImage: "lock")
            }
        } header: {
            Text("Security")
        } footer: {
            Text("The key file is protected by your password. Keep a backup of it and your recovery key apart from your notes.")
        }
    }

    // MARK: Help

    private var helpSection: some View {
        Section {
            NavigationLink {
                HelpView()
            } label: {
                Label("How Quick Diary works", systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("help")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Encryption", value: "AES-256-GCM")
            LabeledContent("Password key", value: "PBKDF2-SHA256 · \(model.iterations.formatted()) rounds")
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
        }
    }
}

/// Re-wraps the master key with the new password. Notes are not touched.
struct ChangePasswordView: View {
    @EnvironmentObject private var model: AppModel
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var done = false
    @State private var working = false

    var body: some View {
        Form {
            Section {
                SecureField("Current password", text: $current)
                    .accessibilityIdentifier("currentPassword")
            }
            Section {
                SecureField("New password", text: $new)
                    .accessibilityIdentifier("newPassword")
                SecureField("Repeat new password", text: $confirm)
                    .accessibilityIdentifier("confirmPassword")
            } footer: {
                Text("Only the key file changes. Your notes stay as they are, so this is quick even with many notes.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            if done {
                Section {
                    Label("Password changed. Back up the key file again.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("passwordChanged")
                }
            }
            Section {
                Button(action: change) {
                    HStack {
                        Text("Change password")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working || current.isEmpty || new.isEmpty)
                .accessibilityIdentifier("applyPasswordChange")
            }
        }
        .navigationTitle("Change password")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: done) { _, new in new }
    }

    private func change() {
        working = true
        error = nil
        done = false
        Task {
            defer { working = false }
            do {
                try await model.changePassword(current: current, new: new, confirm: confirm)
                current = ""; new = ""; confirm = ""
                done = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct RevealRecoveryKeyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var key: String?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            if let key {
                Section {
                    RecoveryKeyCard(key: key)
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Anyone with this key can open your notes. Store it somewhere safe.")
                }
            } else {
                Section {
                    SecureField("Password", text: $password)
                        .onSubmit(reveal)
                        .accessibilityIdentifier("revealPassword")
                } footer: {
                    Text("Enter your password to show the recovery key.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button(action: reveal) {
                        HStack {
                            Text("Show recovery key")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || password.isEmpty)
                    .accessibilityIdentifier("reveal")
                }
            }
        }
        .navigationTitle("Recovery key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reveal() {
        guard !working, !password.isEmpty else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                key = try await model.recoveryKey(password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
