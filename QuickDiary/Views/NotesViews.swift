import SwiftUI

struct NotesListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var path: [Route] = []
    @State private var showSettings = false

    enum Route: Hashable {
        case note(String)
        case new(UUID)
    }

    private var filtered: [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.notes }
        return model.notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.notes.isEmpty {
                    ContentUnavailableView {
                        Label("No notes yet", systemImage: "note.text")
                    } description: {
                        Text("Tap \(Image(systemName: "square.and.pencil")) to write one. It is encrypted before it is saved.")
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List {
                        if model.downloading > 0 || model.unreadable > 0 {
                            Section { statusRows }
                        }
                        ForEach(filtered) { note in
                            NavigationLink(value: Route.note(note.id)) {
                                NoteRow(note: note)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.delete(id: note.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                ShareLink(item: note.text) {
                                    Label("Share as text", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    model.delete(id: note.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { model.reload() }
                }
            }
            .navigationTitle("Notes")
            .searchable(text: $search, prompt: "Search notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.lock() } label: {
                        Label("Lock", systemImage: "lock")
                    }
                    .accessibilityIdentifier("lock")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Text(verbatim: model.notes.count == 1 ? "1 note" : "\(model.notes.count) notes")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button { path.append(.new(UUID())) } label: {
                        Label("New note", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("newNote")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .note(id): EditorView(noteID: id)
                case .new: EditorView(noteID: nil)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    @ViewBuilder private var statusRows: some View {
        if model.downloading > 0 {
            Label("\(model.downloading) notes downloading from iCloud", systemImage: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
        }
        if model.unreadable > 0 {
            Label("\(model.unreadable) notes can't be opened with this key", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(.headline)
                .lineLimit(1)
            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(note.modified, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var noteID: String?
    @State private var text = ""
    @State private var savedText = ""
    @State private var loaded = false
    @State private var mode: Mode = .edit
    @State private var error: String?
    @FocusState private var editorFocused: Bool

    enum Mode: Hashable { case edit, preview }

    init(noteID: String?) {
        _noteID = State(initialValue: noteID)
    }

    var body: some View {
        Group {
            switch mode {
            case .edit:
                TextEditor(text: $text)
                    .focused($editorFocused)
                    .scrollDismissesKeyboard(.interactively)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("editor")
            case .preview:
                ScrollView {
                    MarkdownPreview(text: text)
                        .padding()
                }
                .accessibilityIdentifier("preview")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    Text("Edit").tag(Mode.edit)
                    Text("Preview").tag(Mode.preview)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(text.isEmpty)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button { insertLine("# ") } label: { Label("Heading", systemImage: "number") }
                Button { insertLine("- ") } label: { Label("List", systemImage: "list.bullet") }
                Button { insertLine("- [ ] ") } label: { Label("Checkbox", systemImage: "checklist") }
                Button { insertLine("> ") } label: { Label("Quote", systemImage: "text.quote") }
                Spacer()
                Button("Done") { editorFocused = false }
            }
        }
        .safeAreaInset(edge: .bottom) { statusLine }
        .onAppear(perform: load)
        .onDisappear(perform: save)
        .onChange(of: scenePhase) { _, phase in
            // Save before the app locks itself in the background.
            if phase != .active { save() }
        }
        .task(id: text) {
            // Autosave 1 s after the last keystroke.
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { save() }
        }
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 6) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).foregroundStyle(.red)
            } else {
                Image(systemName: text == savedText ? "lock.fill" : "pencil")
                Text(verbatim: text == savedText ? "Saved, encrypted" : "Editing…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityIdentifier("saveStatus")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let noteID, let note = model.note(id: noteID) {
            text = note.text
            savedText = note.text
        } else {
            editorFocused = true
        }
    }

    private func save() {
        guard text != savedText else { return }
        // A new note with nothing in it is not saved.
        if noteID == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        do {
            let note = try model.save(text: text, id: noteID)
            noteID = note.id
            savedText = text
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// TextEditor has no cursor API before iOS 18, so Markdown markers start a new line at the end.
    private func insertLine(_ marker: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += marker
    }
}
