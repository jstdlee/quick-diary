import SwiftUI

/// iPhone: a list that pushes the editor. iPad: list and editor side by side.
struct NotesListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var selection: Route?
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showSettings = false

    enum Route: Hashable {
        case note(String)
        case new(UUID)
        case deleted
    }

    private var filtered: [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.notes }
        return model.notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [Route] = []

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if isCompact {
                // iPhone: list → editor.
                NavigationStack(path: $path) {
                    listColumn
                        .navigationDestination(for: Route.self) { detail(for: $0) }
                }
            } else {
                // iPad: list and editor side by side.
                NavigationSplitView(columnVisibility: $columns) {
                    listColumn
                } detail: {
                    if let selection {
                        detail(for: selection)
                    } else {
                        ContentUnavailableView {
                            Label("No note selected", systemImage: "note.text")
                        } description: {
                            Text("Choose a note, or press ⌘N to write a new one.")
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear(perform: openPendingEntry)
        .onChange(of: model.pendingNewEntry) { _, _ in openPendingEntry() }
        .onChange(of: model.notes) { _, notes in
            // The open note was deleted: close it.
            if case let .note(id)? = selection, !notes.contains(where: { $0.id == id }) { selection = nil }
        }
    }

    private var listColumn: some View {
        sidebar
            .navigationTitle("Notes")
            .searchable(text: $search, prompt: "Search notes")
            .toolbar { listToolbar }
    }

    @ViewBuilder private func detail(for route: Route) -> some View {
        switch route {
        case let .note(id): EditorView(noteID: id).id(id)
        case let .new(token): EditorView(noteID: nil).id(token)
        case .deleted: DeletedNotesView()
        }
    }

    /// "New entry" from Shortcuts or Siri.
    private func openPendingEntry() {
        guard model.pendingNewEntry else { return }
        model.pendingNewEntry = false
        newNote()
    }

    private func newNote() {
        let route = Route.new(UUID())
        if isCompact { path.append(route) } else { selection = route }
    }

    @ViewBuilder private var sidebar: some View {
        if model.notes.isEmpty && model.deleted.isEmpty {
            ContentUnavailableView {
                Label("No notes yet", systemImage: "note.text")
            } description: {
                Text("Tap \(Image(systemName: "square.and.pencil")) to write one. It is encrypted before it is saved.")
            }
        } else if filtered.isEmpty && !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            // A selection-bound list drives the iPad detail column. On iPhone a plain list,
            // so its links push onto the navigation stack.
            Group {
                if isCompact {
                    List { listRows }
                } else {
                    List(selection: $selection) { listRows }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { model.reload() }
        }
    }

    @ViewBuilder private var listRows: some View {
        if model.downloading > 0 || model.unreadable > 0 {
            Section { statusRows }
        }
        Section {
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
        if !model.deleted.isEmpty && search.isEmpty {
            Section {
                NavigationLink(value: Route.deleted) {
                    Label("Recently Deleted", systemImage: "trash")
                        .badge(model.deleted.count)
                }
                .accessibilityIdentifier("recentlyDeleted")
            }
        }
    }

    @ToolbarContentBuilder private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { model.lock() } label: {
                Label("Lock", systemImage: "lock")
            }
            .keyboardShortcut("l", modifiers: .command)
            .accessibilityIdentifier("lock")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityIdentifier("settings")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            Text(verbatim: model.notes.count == 1 ? "1 note" : "\(model.notes.count) notes")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(action: newNote) {
                Label("New note", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("newNote")
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

/// Deleted notes stay encrypted in the vault's "Recently Deleted" folder until removed here.
struct DeletedNotesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmPurge: [String]?

    var body: some View {
        Group {
            if model.deleted.isEmpty {
                ContentUnavailableView {
                    Label("Nothing deleted", systemImage: "trash")
                } description: {
                    Text("Deleted notes stay here until you delete them permanently.")
                }
            } else {
                List {
                    Section {
                        ForEach(model.deleted) { note in
                            NoteRow(note: note)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        model.restoreDeleted(id: note.id)
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.accentColor)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        confirmPurge = [note.id]
                                    } label: {
                                        Label("Delete permanently", systemImage: "trash.slash")
                                    }
                                }
                                .contextMenu {
                                    Button { model.restoreDeleted(id: note.id) } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    Button(role: .destructive) { confirmPurge = [note.id] } label: {
                                        Label("Delete permanently", systemImage: "trash.slash")
                                    }
                                }
                        }
                    } footer: {
                        Text("Swipe right to restore a note, left to delete it permanently.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.deleted.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete All", role: .destructive) {
                        confirmPurge = model.deleted.map(\.id)
                    }
                }
            }
        }
        .confirmationDialog(
            purgeTitle,
            isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } }),
            titleVisibility: .visible
        ) {
            Button(purgeButton, role: .destructive) {
                if let ids = confirmPurge { model.purgeDeleted(ids: ids) }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var purgeTitle: String {
        (confirmPurge?.count ?? 0) == 1
            ? String(localized: "Delete this note permanently?")
            : String(localized: "Delete \(confirmPurge?.count ?? 0) notes permanently?")
    }

    private var purgeButton: String {
        (confirmPurge?.count ?? 0) == 1
            ? String(localized: "Delete Note")
            : String(localized: "Delete \(confirmPurge?.count ?? 0) Notes")
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
        .accessibilityElement(children: .combine)
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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if mode == .edit {
                    CaptureBar(append: appendLine, onError: { error = $0 })
                }
                statusLine
            }
        }
        .sensoryFeedback(.selection, trigger: mode)
        .background {
            // ⇧⌘P switches Edit / Preview with a hardware keyboard.
            Button("Toggle preview") { mode = mode == .edit ? .preview : .edit }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
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

    /// Adds a whole line (quick entry, weather, photo) at the end of the note.
    private func appendLine(_ line: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += line + "\n"
        error = nil
    }

    /// TextEditor has no cursor API before iOS 18, so Markdown markers start a new line at the end.
    private func insertLine(_ marker: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += marker
    }
}
