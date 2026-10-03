import SwiftUI

/// Settings › Attachments: largest first. The only place attachments are deleted, and always after asking.
struct AttachmentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var items: [AssetStore.Info] = []
    @State private var pendingDelete: AssetStore.Info?

    private var total: Int64 { items.reduce(0) { $0 + $1.size } }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No attachments", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Photos and scans you add to notes show here, largest first.")
                }
            } else {
                List {
                    Section {
                        ForEach(items) { item in
                            AttachmentRow(item: item, references: model.references(to: item.id))
                                .swipeActions {
                                    Button(role: .destructive) { pendingDelete = item } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) { pendingDelete = item } label: {
                                        Label("Delete…", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text("\(items.count) attachments · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    } footer: {
                        Text("Deleting a note keeps its attachments. They are encrypted like your notes.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Attachments")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .confirmationDialog(deleteTitle, isPresented: deleteShown, titleVisibility: .visible, presenting: pendingDelete) { item in
            Button("Delete Attachment", role: .destructive) {
                try? model.deleteAttachment(item.id)
                refresh()
            }
        } message: { item in
            Text(deleteMessage(item))
        }
    }

    private func refresh() { items = model.attachments() }

    private var deleteShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let item = pendingDelete else { return "" }
        return String(localized: "Delete this attachment (\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)))?")
    }

    private func deleteMessage(_ item: AssetStore.Info) -> String {
        let count = model.references(to: item.id)
        if count == 0 { return String(localized: "No note uses it. This can't be undone.") }
        return count == 1
            ? String(localized: "1 note uses it and will show \"Attachment not found\". This can't be undone.")
            : String(localized: "\(count) notes use it and will show \"Attachment not found\". This can't be undone.")
    }
}

struct AttachmentRow: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetStore.Info
    let references: Int
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.fill.tertiary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .monospacedDigit()
                Text(references == 0 ? String(localized: "Not used in a note")
                     : references == 1 ? String(localized: "Used in 1 note")
                     : String(localized: "Used in \(references) notes"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(item.created, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: item.id) {
            guard let image = await model.image(at: item.id) else { return }
            thumbnail = image.preparingThumbnail(of: CGSize(width: 112, height: 112)) ?? image
        }
    }
}
