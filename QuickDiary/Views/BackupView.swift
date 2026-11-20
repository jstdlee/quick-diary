import SwiftUI

/// Settings › Backup: several S3-compatible buckets and private GitHub repos, plus an encrypted .zip.
struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var destinations = DestinationLibrary.load()
    @State private var editor: BackupDestination?
    @State private var running: String?
    @State private var progress: (name: String, done: Int, total: Int) = ("", 0, 0)
    @State private var status: String?
    @State private var failed = false
    @State private var confirmRestore = false
    @State private var showRestorePicker = false
    @State private var restoreTarget: BackupDestination?
    @State private var pendingDeleteIDs: [UUID] = []
    @State private var confirmDelete = false
    @State private var zipURL: URL?

    /// Demo and UI tests back up to memory, with no credentials.
    private static let demoStore = MemoryStore()

    private var runnable: [BackupDestination] {
        destinations.filter { $0.store(secret: Secrets.get(DestinationLibrary.secretAccount($0.id)) ?? "") != nil }
    }

    var body: some View {
        Form {
            Section {
                ForEach(destinations) { destination in
                    Button { editor = destination } label: { row(destination) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    pendingDeleteIDs = offsets.map { destinations[$0].id }
                    confirmDelete = true
                }
                Button { editor = .fresh() } label: {
                    Label("Add destination", systemImage: "plus")
                }
            } header: {
                Text("Destinations")
            } footer: {
                Text("S3-compatible storage (AWS, R2, MinIO) or a private GitHub repo. Secrets stay in this iPhone's Keychain. The folder on this iPhone is still the vault.")
            }

            Section {
                Button(action: backUp) {
                    HStack {
                        Label("Back up now", systemImage: "arrow.up.to.line")
                        Spacer()
                        if running == "backup" { ProgressView() }
                    }
                }
                .disabled(backupDisabled)
                .accessibilityIdentifier("backupNow")
                if running != nil, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text(progress.name.isEmpty
                             ? "\(progress.done) of \(progress.total) files"
                             : "\(progress.name): \(progress.done) of \(progress.total) files")
                            .font(.footnote).monospacedDigit()
                    }
                }
                if let status {
                    Label(status, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? Color.red : Color.green)
                        .accessibilityIdentifier("backupStatus")
                }
                Button {
                    if runnable.count <= 1 {
                        restoreTarget = runnable.first
                        confirmRestore = true
                    } else {
                        showRestorePicker = true
                    }
                } label: {
                    HStack {
                        Label("Restore missing files", systemImage: "arrow.down.to.line")
                        Spacer()
                        if running == "restore" { ProgressView() }
                    }
                }
                .disabled(backupDisabled)
            } footer: {
                Text("Files are encrypted before they leave this iPhone, so the storage provider can't read them; it sees file names and sizes. Only new and changed files are uploaded. One destination failing does not stop the others.")
            }

            Section {
                if let zipURL {
                    ShareLink(item: zipURL) {
                        Label("Share encrypted copy (.zip)", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button(action: makeZip) {
                        Label("Make encrypted copy (.zip)", systemImage: "doc.zipper")
                    }
                }
            } header: {
                Text("Other backups")
            } footer: {
                Text("Send the .zip to yourself by Mail or Gmail, or save it in Files. For iCloud Drive, choose it in Storage. Every copy needs your password or recovery key to open.")
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editor) { destination in
            DestinationEditor(starting: destination) { updated in
                upsert(updated)
            } onDelete: {
                remove(destination.id)
            }
        }
        .confirmationDialog("Delete this destination?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                pendingDeleteIDs.forEach(remove)
                pendingDeleteIDs = []
            }
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text("The saved secret is removed from this iPhone. Files already copied stay where they are.")
        }
        .confirmationDialog("Restore from?", isPresented: $showRestorePicker, titleVisibility: .visible) {
            ForEach(runnable) { destination in
                Button(destination.title) {
                    restoreTarget = destination
                    DispatchQueue.main.async { confirmRestore = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Restore missing files?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore Missing Files", action: restore)
        } message: {
            Text("Downloads files this vault doesn't have. Nothing here is replaced or deleted.")
        }
        .onChange(of: destinations) { _, new in DestinationLibrary.save(new) }
    }

    private var backupDisabled: Bool {
        if running != nil || model.folder == nil { return true }
        if model.options.isDemo { return false }
        return runnable.isEmpty
    }

    private func row(_ destination: BackupDestination) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title)
                Text(subtitle(destination))
                    .font(.footnote)
                    .foregroundStyle(destination.lastError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func subtitle(_ destination: BackupDestination) -> String {
        let kind = destination.kind == .s3 ? "S3" : "GitHub"
        if let error = destination.lastError, !error.isEmpty { return "\(kind) · \(error)" }
        if let date = destination.lastBackup {
            return "\(kind) · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return destination.enabled ? kind : "\(kind) · off"
    }

    private func upsert(_ destination: BackupDestination) {
        if let index = destinations.firstIndex(where: { $0.id == destination.id }) {
            destinations[index] = destination
        } else if destination.hasCredentials || !destination.name.isEmpty {
            destinations.append(destination)
        }
    }

    private func remove(_ id: UUID) {
        Secrets.set("", for: DestinationLibrary.secretAccount(id))
        destinations.removeAll { $0.id == id }
    }

    private func backUp() {
        guard let folder = model.folder else { return }
        start("backup")
        Task {
            defer { running = nil }
            if model.options.isDemo {
                await runDemo(folder: folder)
                return
            }
            let targets = runnable
            let jobs: [(name: String, store: ObjectStore, prefix: String)] = targets.compactMap { destination in
                let secret = Secrets.get(DestinationLibrary.secretAccount(destination.id)) ?? ""
                guard let store = destination.store(secret: secret) else { return nil }
                return (destination.title, store, destination.prefix)
            }
            let runs = await BackupEngine.backUp(folder: folder, destinations: jobs) { name, done, total in
                Task { @MainActor in progress = (name, done, total) }
            }
            let now = Date()
            for (run, destination) in zip(runs, targets) {
                guard let index = destinations.firstIndex(where: { $0.id == destination.id }) else { continue }
                if run.error == nil {
                    destinations[index].lastBackup = now
                    destinations[index].lastError = nil
                } else {
                    destinations[index].lastError = run.error
                }
            }
            failed = runs.contains { $0.error != nil }
            status = runs.map(Self.line).joined(separator: "\n")
            if !failed { status = "Backed up: \(status ?? "")" }
        }
    }

    private func runDemo(folder: URL) async {
        do {
            let summary = try await BackupEngine.backUp(folder: folder, to: Self.demoStore, prefix: "quick-diary") { done, total in
                Task { @MainActor in progress = ("", done, total) }
            }
            let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
            status = String(localized: "Backed up: \(summary.uploaded) files uploaded (\(size)), \(summary.unchanged) unchanged.")
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }

    private static func line(_ run: BackupEngine.Run) -> String {
        if let error = run.error { return "\(run.name): \(error)" }
        guard let summary = run.summary else { return run.name }
        var text = "\(run.name): \(summary.uploaded) uploaded, \(summary.unchanged) unchanged"
        if summary.skipped > 0 { text += ", \(summary.skipped) too large for GitHub" }
        return text
    }

    private func restore() {
        guard let folder = model.folder else { return }
        start("restore")
        Task {
            defer { running = nil }
            do {
                let count: Int
                if model.options.isDemo {
                    count = try await BackupEngine.restoreMissing(folder: folder, from: Self.demoStore, prefix: "quick-diary") { done, total in
                        Task { @MainActor in progress = ("", done, total) }
                    }
                } else if let target = restoreTarget,
                          let store = target.store(secret: Secrets.get(DestinationLibrary.secretAccount(target.id)) ?? "") {
                    count = try await BackupEngine.restoreMissing(folder: folder, from: store, prefix: target.prefix) { done, total in
                        Task { @MainActor in progress = (target.title, done, total) }
                    }
                } else {
                    return
                }
                model.reload()
                status = count == 0 ? String(localized: "Nothing to restore: this vault has every file.")
                    : String(localized: "Restored \(count) files.")
            } catch {
                failed = true
                status = error.localizedDescription
            }
        }
    }

    private func start(_ job: String) {
        running = job
        status = nil
        failed = false
        progress = ("", 0, 0)
    }

    private func makeZip() {
        guard let folder = model.folder else { return }
        do {
            zipURL = try BackupEngine.exportZip(folder: folder)
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }
}

/// One destination. Changes are kept as they are typed.
private struct DestinationEditor: View {
    @State private var destination: BackupDestination
    @State private var secret: String
    var onCommit: (BackupDestination) -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(starting: BackupDestination, onCommit: @escaping (BackupDestination) -> Void, onDelete: @escaping () -> Void) {
        _destination = State(initialValue: starting)
        _secret = State(initialValue: Secrets.get(DestinationLibrary.secretAccount(starting.id)) ?? "")
        self.onCommit = onCommit
        self.onDelete = onDelete
    }

    var body: some View {
        Form {
            Picker("Kind", selection: $destination.kind) {
                Text("S3").tag(BackupDestination.Kind.s3)
                Text("GitHub").tag(BackupDestination.Kind.github)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("destinationKind")

            LabeledContent("Name") {
                TextField(destination.kind == .s3 ? "My bucket" : "My repo", text: $destination.name)
                    .multilineTextAlignment(.trailing)
            }

            if destination.kind == .s3 {
                s3Fields
            } else {
                githubFields
            }

            Toggle("Enabled", isOn: $destination.enabled)

            Section {
                Button("Delete destination", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: destination) { _, new in onCommit(new) }
        .onChange(of: secret) { _, new in
            Secrets.set(new, for: DestinationLibrary.secretAccount(destination.id))
        }
        .confirmationDialog("Delete this destination?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved secret is removed from this iPhone. Files already copied stay where they are.")
        }
    }

    @ViewBuilder private var s3Fields: some View {
        Section {
            field("Endpoint", text: $destination.endpoint, prompt: "https://<account>.r2.cloudflarestorage.com", url: true)
            field("Region", text: $destination.region, prompt: "auto", url: false)
            field("Bucket", text: $destination.bucket, prompt: "my-diary", url: false)
            field("Folder in bucket", text: $destination.prefix, prompt: "quick-diary", url: false)
            field("Access key ID", text: $destination.accessKeyID, prompt: "Required", url: false)
            LabeledContent("Secret key") {
                SecureField("Required", text: $secret).multilineTextAlignment(.trailing)
            }
        } footer: {
            Text("AWS S3, Cloudflare R2, MinIO and other S3-compatible storage.")
        }
    }

    @ViewBuilder private var githubFields: some View {
        Section {
            field("Owner", text: $destination.owner, prompt: "octocat", url: false)
            field("Repo", text: $destination.repo, prompt: "diary", url: false)
            field("Branch", text: $destination.branch, prompt: "default branch", url: false)
            field("Folder", text: $destination.prefix, prompt: "quick-diary", url: false)
            LabeledContent("Token") {
                SecureField("Required", text: $secret).multilineTextAlignment(.trailing)
            }
        } footer: {
            Text("A fine-grained personal access token with contents access on this private github.com repo. A public repo is refused.")
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, url: Bool) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(url ? .URL : .default)
        }
    }
}
