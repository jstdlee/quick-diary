import SwiftUI

/// Settings › How Quick Diary works: concepts, Markdown, keyboard shortcuts.
struct HelpView: View {
    private struct Concept: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let text: String
    }

    private let concepts: [Concept] = [
        Concept(icon: "folder", title: "Vault",
                text: "A folder with your encrypted notes and its key file. Copy the folder to move or back up everything."),
        Concept(icon: "lock", title: "Password",
                text: "Unlocks the key file. Changing it is instant: the notes are not encrypted again."),
        Concept(icon: "key", title: "Key file",
                text: "quick-diary-key.json, next to the notes. It holds the master key, locked by your password."),
        Concept(icon: "key.viewfinder", title: "Recovery key",
                text: "64 characters, shown at setup. It sets a new password if you forget yours. Anyone with it can read your notes."),
        Concept(icon: "externaldrive", title: "Storage",
                text: "On this iPhone, iCloud Drive, or any folder in Files. Switching copies notes; nothing is deleted."),
        Concept(icon: "trash", title: "Recently Deleted",
                text: "Deleted notes stay there, still encrypted, until you delete them permanently."),
    ]

    private let markdown: [(source: String, result: String)] = [
        ("# Heading", "Large title (## and ### for smaller)"),
        ("- Item", "Bulleted list"),
        ("1. Item", "Numbered list"),
        ("- [ ] Task", "Checkbox; - [x] is done"),
        ("> Quote", "Quoted text"),
        ("**bold** *italic*", "Bold and italic"),
        ("`code`", "Inline code; ``` for a block"),
        ("[link](https://…)", "Link"),
    ]

    private let shortcuts: [(keys: String, action: String)] = [
        ("⌘N", "New note"),
        ("⌘F", "Search notes"),
        ("⇧⌘P", "Edit / Preview"),
        ("⌘,", "Settings"),
        ("⌘L", "Lock"),
    ]

    var body: some View {
        List {
            Section("Concepts") {
                ForEach(concepts) { concept in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(concept.title)
                            Text(concept.text)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: concept.icon).foregroundStyle(.tint)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section("Markdown") {
                ForEach(markdown, id: \.source) { item in
                    LabeledContent {
                        Text(item.result).multilineTextAlignment(.trailing)
                    } label: {
                        Text(item.source).font(.body.monospaced())
                    }
                }
            }
            Section {
                ForEach(shortcuts, id: \.keys) { item in
                    LabeledContent(item.action) {
                        Text(item.keys).font(.body.monospaced())
                    }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("With a hardware keyboard on iPad or iPhone. Hold ⌘ to see them all.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("How Quick Diary works")
        .navigationBarTitleDisplayMode(.inline)
    }
}
