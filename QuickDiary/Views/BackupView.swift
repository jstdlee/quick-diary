import SwiftUI

/// Settings › Backup: S3 / R2, plus an encrypted .zip for Mail, Gmail, Files or AirDrop.
struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var config = BackupConfig.load()
    @State private var secret = Secrets.get(Secrets.s3Secret) ?? ""
    @State private var running: String?
    @State private var progress: (done: Int, total: Int) = (0, 0)
    @State private var status: String?
    @State private var failed = false
    @State private var confirmRestore = false
    @State private var zipURL: URL?
    @AppStorage("lastBackup") private var lastBackup: Double = 0

    /// Demo and UI tests back up to memory.
    private static let demoStore = MemoryStore()

    private var store: ObjectStore? {
        model.options.isDemo ? Self.demoStore : config.store(secret: secret)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Endpoint") {
                    TextField("https://<account>.r2.cloudflarestorage.com", text: $config.endpoint)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Region") {
                    TextField("auto", text: $config.region)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Bucket") {
                    TextField("my-diary", text: $config.bucket)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Folder in bucket") {
                    TextField("quick-diary", text: $config.prefix)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Access key ID") {
                    TextField("Required", text: $config.accessKeyID)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Secret key") {
                    SecureField("Required", text: $secret)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("S3 or R2")
            } footer: {
                Text("AWS S3, Cloudflare R2, MinIO and other S3-compatible storage. The secret key is kept in this iPhone's Keychain.")
            }

            Section {
                Button(action: backUp) {
                    HStack {
                        Label("Back up now", systemImage: "arrow.up.to.line")
                        Spacer()
                        if running == "backup" { ProgressView() }
                    }
                }
                .disabled(store == nil || running != nil || model.folder == nil)
                .accessibilityIdentifier("backupNow")
                if running != nil, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text("\(progress.done) of \(progress.total) files").font(.footnote).monospacedDigit()
                    }
                }
                if let status {
                    Label(status, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? Color.red : Color.green)
                        .accessibilityIdentifier("backupStatus")
                } else if lastBackup > 0 {
                    LabeledContent("Last backup",
                                   value: Date(timeIntervalSince1970: lastBackup).formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    confirmRestore = true
                } label: {
                    HStack {
                        Label("Restore missing files", systemImage: "arrow.down.to.line")
                        Spacer()
                        if running == "restore" { ProgressView() }
                    }
                }
                .disabled(store == nil || running != nil || model.folder == nil)
            } footer: {
                Text("Files are encrypted before they leave this iPhone, so the storage provider can't read them; it sees file names and sizes. Only new and changed files are uploaded.")
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
        .onChange(of: config) { _, new in new.save() }
        .onChange(of: secret) { _, new in Secrets.set(new, for: Secrets.s3Secret) }
        .confirmationDialog("Restore missing files?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore Missing Files", action: restore)
        } message: {
            Text("Downloads files this vault doesn't have. Nothing here is replaced or deleted.")
        }
    }

    private func backUp() {
        guard let store, let folder = model.folder else { return }
        start("backup")
        Task {
            defer { running = nil }
            do {
                let summary = try await BackupEngine.backUp(folder: folder, to: store, prefix: config.prefix) { done, total in
                    Task { @MainActor in progress = (done, total) }
                }
                lastBackup = Date().timeIntervalSince1970
                let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
                status = String(localized: "Backed up: \(summary.uploaded) files uploaded (\(size)), \(summary.unchanged) unchanged.")
            } catch {
                failed = true
                status = error.localizedDescription
            }
        }
    }

    private func restore() {
        guard let store, let folder = model.folder else { return }
        start("restore")
        Task {
            defer { running = nil }
            do {
                let count = try await BackupEngine.restoreMissing(folder: folder, from: store, prefix: config.prefix) { done, total in
                    Task { @MainActor in progress = (done, total) }
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
        progress = (0, 0)
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
