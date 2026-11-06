import SwiftUI

/// Settings › Replace encryption key. Nothing changes until the third confirmation:
/// 1. What happens (with counts) and when to use it → "I understand".
/// 2. The new recovery key is shown and must be saved; the last 8 characters are typed back.
/// 3. Type REPLACE, then confirm in an alert.
/// Then progress (Pause is safe) and the next steps.
struct RotateKeyView: View {
    private enum Step { case impact, passwords, recoveryKey, confirm, running, done }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.impact
    @State private var stats: RotationStats?
    @State private var understood = false
    @State private var current = ""
    @State private var newPassword = ""
    @State private var repeatPassword = ""
    @State private var recovery = ""
    @State private var tail = ""
    @State private var savedBoth = false
    @State private var typed = ""
    @State private var askFinal = false
    @State private var working = false
    @State private var error: String?
    @State private var result: RotationProgress?
    @State private var backupURL: URL?

    var body: some View {
        Form {
            switch step {
            case .impact: impact
            case .passwords: passwords
            case .recoveryKey: recoveryKeyStep
            case .confirm: confirmStep
            case .running: running
            case .done: done
            }
        }
        .navigationTitle("Replace encryption key")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(step == .running)
        .interactiveDismissDisabled(step == .running)
        .task { if stats == nil { stats = await model.rotationStats() } }
        .alert("Replace the encryption key now?", isPresented: $askFinal) {
            Button("Replace key", role: .destructive, action: start)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(total) files are re-encrypted with the new key. This can't be undone.")
        }
        .sensoryFeedback(.success, trigger: step) { _, new in new == .done }
    }

    private var total: Int { stats?.total ?? 0 }

    private func bullet(_ text: Text) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 6))
        }
    }

    @ViewBuilder private var errorSection: some View {
        if let error {
            Section { Text(error).foregroundStyle(.red) }
        }
    }

    // MARK: 1 · Impact

    @ViewBuilder private var impact: some View {
        Section {
            Label("Use this only if your key may have leaked", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            bullet(Text("Your password leaked, and an old copy of the key file may exist (iCloud, a backup, an exported key file)."))
            bullet(Text("Your recovery key leaked."))
        } header: {
            Text("Confirmation 1 of 3")
        } footer: {
            Text("Only want a new password? Change password is instant and doesn't touch your notes.")
        }
        Section {
            NavigationLink("Change password instead") { ChangePasswordView() }
        }
        Section("What happens") {
            if let stats {
                bullet(Text("\(stats.notes) notes, \(stats.deleted) in Recently Deleted, \(stats.attachments) attachments and \(stats.inbox) Shortcuts items (\(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file))) are re-encrypted with a new key."))
                if stats.downloading > 0 {
                    Label("\(stats.downloading) files are still downloading from iCloud. Wait until they're on this device.",
                          systemImage: "icloud.and.arrow.down")
                        .foregroundStyle(.orange)
                }
            } else {
                ProgressView()
            }
            bullet(Text("You choose a new password and get a new recovery key. The old password, old recovery key and old key file backups stop working."))
            bullet(Text("Other devices using this folder lock, and unlock again with the new password."))
            bullet(Text("If it's interrupted, nothing is lost: finish it with the new password."))
            bullet(Text("It can't be undone. Copies made earlier (backups, exported .zip files, the S3 backup) still open with the old key."))
                .foregroundStyle(.orange)
        }
        Section {
            Toggle("I understand: every note and attachment is re-encrypted, and this can't be undone.", isOn: $understood)
                .accessibilityIdentifier("rotateUnderstand")
            Button("Continue") { step = .passwords }
                .disabled(!understood || stats == nil || (stats?.downloading ?? 0) > 0)
                .accessibilityIdentifier("rotateContinue")
        }
    }

    // MARK: Passwords

    @ViewBuilder private var passwords: some View {
        Section {
            SecureField("Current password", text: $current)
                .accessibilityIdentifier("rotateCurrent")
        }
        Section {
            SecureField("New password", text: $newPassword)
                .accessibilityIdentifier("rotateNew")
            SecureField("Repeat new password", text: $repeatPassword)
                .accessibilityIdentifier("rotateRepeat")
        } footer: {
            Text("Save the new password in your password manager now. Other devices need it.")
        }
        errorSection
        Section {
            Button(action: prepare) {
                HStack {
                    Text("Continue")
                    Spacer()
                    if working { ProgressView() }
                }
            }
            .disabled(working || current.isEmpty || newPassword.isEmpty || repeatPassword.isEmpty)
            .accessibilityIdentifier("rotatePasswordsContinue")
            Button("Back") {
                error = nil
                step = .impact
            }
        }
    }

    private func prepare() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                recovery = try await model.prepareRotation(current: current, new: newPassword, confirm: repeatPassword)
                current = ""; newPassword = ""; repeatPassword = ""
                tail = ""
                savedBoth = false
                step = .recoveryKey
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: 2 · New recovery key

    private var tailMatches: Bool {
        let expected = String(recovery.filter(\.isHexDigit).suffix(8)).uppercased()
        return expected.count == 8 && tail.filter(\.isHexDigit).uppercased() == expected
    }

    @ViewBuilder private var recoveryKeyStep: some View {
        Section {
            RecoveryKeyCard(key: recovery)
                .listRowBackground(Color.clear)
        } header: {
            Text("Confirmation 2 of 3 · Your new recovery key")
        } footer: {
            Text("It replaces your old recovery key. Keep it offline, apart from your notes. Nothing has changed yet.")
        }
        Section {
            TextField("Last 8 characters of the new key", text: $tail)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("rotateKeyTail")
            Toggle("I saved the new recovery key and the new password", isOn: $savedBoth)
                .accessibilityIdentifier("rotateSaved")
        } footer: {
            Text("Type the last two groups of the key to show you have it.")
        }
        Section {
            Button("Continue") { step = .confirm }
                .disabled(!tailMatches || !savedBoth)
                .accessibilityIdentifier("rotateKeyContinue")
            Button("Back") {
                // This key was never used; a new one is made after the passwords.
                model.discardPreparedRotation()
                recovery = ""
                step = .passwords
            }
        }
    }

    // MARK: 3 · Final check

    private var typedReplace: Bool { typed.trimmingCharacters(in: .whitespaces).uppercased() == "REPLACE" }

    @ViewBuilder private var confirmStep: some View {
        Section {
            bullet(Text("\(total) files are re-encrypted. Keep Quick Diary open until it finishes."))
            bullet(Text("Other devices lock and need the new password."))
            bullet(Text("The old password and the old recovery key stop working."))
        } header: {
            Text("Confirmation 3 of 3")
        }
        Section {
            TextField("REPLACE", text: $typed)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("rotateTypeReplace")
        } footer: {
            Text("Type REPLACE to confirm.")
        }
        errorSection
        Section {
            Button(role: .destructive) {
                askFinal = true
            } label: {
                Text("Re-encrypt \(total) files")
            }
            .disabled(!typedReplace)
            .accessibilityIdentifier("rotateStart")
            Button("Back") {
                typed = ""
                error = nil
                step = .recoveryKey
            }
        }
    }

    private func start() {
        error = nil
        step = .running
        Task {
            do {
                result = try await model.startRotation()
                backupURL = try? model.keyBackupURL()
                step = .done
            } catch {
                // Before anything changed: back to the final check. After that, the app shows
                // "Finish replacing the key" instead of this screen.
                self.error = error.localizedDescription
                step = .confirm
            }
        }
    }

    // MARK: Running and done

    @ViewBuilder private var running: some View {
        let progress = model.rotationProgress ?? RotationProgress()
        Section {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                Text("Re-encrypting…")
            } currentValueLabel: {
                Text("\(progress.done) of \(progress.total) files")
            }
            .accessibilityIdentifier("rotateProgress")
        } footer: {
            Text("Keep Quick Diary open. Pausing is safe: finish later with the new password.")
        }
        Section {
            Button("Pause") { model.pauseRotation() }
        }
    }

    @ViewBuilder private var done: some View {
        Section {
            Label("The encryption key was replaced", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .accessibilityIdentifier("rotationDone")
            if let result, result.unreadable > 0 {
                Text("\(result.unreadable) files couldn't be opened with either key and were left as they were.")
                    .foregroundStyle(.orange)
            }
        }
        Section("Next steps") {
            bullet(Text("Other devices: unlock with the new password."))
            if let backupURL {
                ShareLink(item: backupURL) {
                    Label("Back up the new key file", systemImage: "square.and.arrow.up")
                }
            }
            bullet(Text("Delete old key file backups, old .zip backups and the old recovery key."))
            bullet(Text("S3 backup: back up again. Notes deleted since an earlier backup stay there with the old key; remove them in your storage."))
            bullet(Text("Copies made before (backups of this iPhone, iCloud Drive's Recently Deleted) still open with the old key."))
        }
        Section {
            Button("Done") { dismiss() }
        }
    }
}

/// Shown at launch (and instead of Unlock) while `quick-diary-rotation.json` exists.
struct FinishRotationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 44

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: iconSize))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Finish replacing the key")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("A key replacement isn't finished. Enter the new password chosen for it. Files already done are skipped.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.keyNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                if working, let progress = model.rotationProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(progress.done) of \(progress.total) files")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("New password", text: $password)
                        .textContentType(.password)
                        .focused($focused)
                        .onSubmit(finish)
                        .padding(12)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("finishRotationPassword")
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button(action: finish) {
                        Text("Finish")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("finishRotation")
                }
            }
            .frame(maxWidth: 420)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear { focused = true }
    }

    private func finish() {
        guard !working, !password.isEmpty else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.resumeRotation(newPassword: password)
            } catch {
                self.error = error.localizedDescription
            }
            password = ""
        }
    }
}
