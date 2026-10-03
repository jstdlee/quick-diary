import AppIntents
import Foundation

extension Notification.Name {
    static let quickDiaryNewEntry = Notification.Name("quickDiaryNewEntry")
}

/// Requests from Shortcuts that arrive before the UI is ready.
@MainActor
enum IntentRequests {
    static var newEntry = false
}

/// Opens Quick Diary on a new note (after unlock).
struct NewEntryIntent: AppIntent {
    static var title: LocalizedStringResource = "New Quick Diary entry"
    static var description = IntentDescription("Opens Quick Diary on a new note.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRequests.newEntry = true
        NotificationCenter.default.post(name: .quickDiaryNewEntry, object: nil)
        return .result()
    }
}

/// Adds text to today's "From Shortcuts" note. Works while Quick Diary is locked:
/// the text is encrypted at once with the vault's public key and added at the next unlock.
/// Use it to bring in Apple Notes, Health or anything else Shortcuts can read.
struct AddToDiaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Quick Diary"
    static var description = IntentDescription(
        "Adds text to today's diary. The text is encrypted right away and shows after you unlock Quick Diary.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Source", description: "Shown before the text, e.g. Health or Apple Notes.", default: "Shortcuts")
    var source: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Quick Diary") {
            \.$source
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (folder, scoped) = try await Inbox.currentVaultFolder()
        defer { scoped?.stopAccessingSecurityScopedResource() }
        guard let keyFile = try KeyFileIO.read(in: folder) else {
            throw VaultError.folderUnavailable
        }
        try Inbox.add(InboxItem(date: Date(), text: text, source: source), folder: folder, keyFile: keyFile)
        return .result(dialog: "Added to Quick Diary. It shows after you unlock.")
    }
}

struct QuickDiaryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewEntryIntent(),
                    phrases: ["New \(.applicationName) entry", "Write in \(.applicationName)"],
                    shortTitle: "New entry",
                    systemImageName: "square.and.pencil")
        AppShortcut(intent: AddToDiaryIntent(),
                    phrases: ["Add to \(.applicationName)"],
                    shortTitle: "Add to diary",
                    systemImageName: "text.badge.plus")
    }
}
