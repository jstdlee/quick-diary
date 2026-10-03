import SwiftUI

/// Settings › Quick entries: the menus under the editor.
struct QuickListsView: View {
    @EnvironmentObject private var store: QuickListStore
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                ForEach($store.lists) { $list in
                    NavigationLink {
                        QuickListEditor(list: $list)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name)
                                Text(list.options.joined(separator: " · "))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: list.symbol).foregroundStyle(.tint)
                        }
                    }
                }
                .onDelete { store.lists.remove(atOffsets: $0) }
                .onMove { store.lists.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    store.lists.append(QuickList(name: "New list", symbol: "star", options: ["Option 1"]))
                } label: {
                    Label("Add list", systemImage: "plus")
                }
            } footer: {
                Text("Each list is a menu under the editor. Picking an option adds a line like \"- Mood: 🙂 Good\".")
            }
            Section {
                Button("Restore default lists") { confirmReset = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Quick entries")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .confirmationDialog("Restore the default lists?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Restore Defaults", role: .destructive) { store.resetToDefaults() }
        } message: {
            Text("Your own lists are replaced by Mood, Meal and Sport. Notes are not changed.")
        }
    }
}

struct QuickListEditor: View {
    @Binding var list: QuickList
    @State private var newOption = ""

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $list.name)
            }
            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44)), count: 6), spacing: 12) {
                    ForEach(QuickList.symbols, id: \.self) { symbol in
                        Button {
                            list.symbol = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(list.symbol == symbol ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(list.symbol == symbol ? Color.accentColor : Color.primary)
                        .accessibilityLabel(Text(symbol))
                        .accessibilityAddTraits(list.symbol == symbol ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                // By position, so typing in a field doesn't rebuild it.
                ForEach(list.options.indices, id: \.self) { index in
                    TextField("Option", text: $list.options[index])
                }
                .onDelete { list.options.remove(atOffsets: $0) }
                .onMove { list.options.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("Add an option, e.g. 🍵 Tea", text: $newOption)
                        .onSubmit(addOption)
                    Button("Add", action: addOption)
                        .disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Options")
            } footer: {
                Text("Adds \"\(list.line(for: list.options.first ?? "…"))\" to the note.")
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func addOption() {
        let option = newOption.trimmingCharacters(in: .whitespaces)
        guard !option.isEmpty else { return }
        list.options.append(option)
        newOption = ""
    }
}
