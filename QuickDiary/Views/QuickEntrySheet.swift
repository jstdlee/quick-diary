import PhotosUI
import SwiftUI

/// Home Screen quick action → one thumb-friendly screen: date/time, place, weather, mood,
/// text (typed or dictated), and photos. Saves one Markdown note and dismisses; it never
/// opens the editor. Reuses `Weather.Now.line` and `QuickList.line(for:)` so the lines match
/// the editor's quick entries.
struct QuickEntrySheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quickLists: QuickListStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dictation = Dictation()

    @State private var date = Date.now
    @State private var place: String?
    @State private var placeError: String?
    @State private var loadingPlace = false
    @State private var weather: Weather.Now?
    @State private var weatherError: String?
    @State private var loadingWeather = false
    @State private var mood: String?
    @State private var text = ""
    @State private var dictationBase = ""
    @State private var images: [UIImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var error: String?
    @State private var saved = false
    @FocusState private var textFocused: Bool

    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
    private let maxPhotos = 5

    private var moodList: QuickList? {
        quickLists.lists.first { $0.name == "Mood" } ?? QuickList.defaults.first { $0.name == "Mood" }
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                if let moodList { moodSection(moodList) }
                textSection
                imagesSection
            }
            .navigationTitle("Quick entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("qe-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isEmpty)
                        .accessibilityIdentifier("qe-save")
                }
            }
        }
        .accessibilityIdentifier("quickEntrySheet")
        .sensoryFeedback(.success, trigger: saved) { _, new in new }
        .task {
            textFocused = true
            await loadPlace()
            await loadWeather()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in if images.count < maxPhotos { images.append(image) } }
                .ignoresSafeArea()
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            DatePicker("Date & time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .accessibilityIdentifier("qe-date")
            placeRow
            weatherRow
        }
    }

    @ViewBuilder private var placeRow: some View {
        if let place {
            HStack {
                Label(place, systemImage: "location.fill")
                Spacer()
                Button { self.place = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("qe-place")
        } else {
            Button { Task { await loadPlace() } } label: {
                HStack {
                    Label(placeError ?? String(localized: "Add place"), systemImage: "location")
                    Spacer()
                    if loadingPlace { ProgressView() }
                }
            }
            .accessibilityIdentifier("qe-place")
        }
    }

    @ViewBuilder private var weatherRow: some View {
        if let weather {
            HStack {
                Label(String(weather.line.dropFirst(2)), systemImage: "cloud.sun.fill")
                Spacer()
                Button { self.weather = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("qe-weather")
        } else {
            Button { Task { await loadWeather() } } label: {
                HStack {
                    Label(weatherError ?? String(localized: "Add weather"), systemImage: "cloud.sun")
                    Spacer()
                    if loadingWeather { ProgressView() }
                }
            }
            .accessibilityIdentifier("qe-weather")
        }
    }

    // MARK: Mood

    private func moodSection(_ list: QuickList) -> some View {
        Section("Mood") {
            HStack(spacing: 4) {
                ForEach(Array(list.options.enumerated()), id: \.offset) { index, option in
                    // "😄 Great": big emoji, its word small below, one line each.
                    let parts = option.split(separator: " ", maxSplits: 1).map(String.init)
                    Button {
                        mood = (mood == option) ? nil : option
                    } label: {
                        VStack(spacing: 2) {
                            Text(parts.first ?? option).font(.title)
                            if parts.count > 1 {
                                Text(parts[1])
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(mood == option ? Color.accentColor.opacity(0.2) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option)
                    .accessibilityAddTraits(mood == option ? .isSelected : [])
                    .accessibilityIdentifier("qe-mood-\(index)")
                }
            }
            .sensoryFeedback(.selection, trigger: mood)
        }
    }

    // MARK: Text and voice

    private var textSection: some View {
        Section {
            HStack(alignment: .top) {
                TextField("What's on your mind?", text: $text, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($textFocused)
                    .accessibilityIdentifier("qe-text")
                if !model.options.isDemo {
                    Button(action: toggleDictation) {
                        Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                            .foregroundStyle(dictation.isListening ? .red : .secondary)
                            .symbolEffect(.pulse, isActive: dictation.isListening)
                    }
                    .accessibilityIdentifier("qe-mic")
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: Photos

    private var imagesSection: some View {
        Section {
            HStack {
                PhotosPicker(selection: $photoItems, maxSelectionCount: maxPhotos, matching: .images) {
                    Label("Photo library", systemImage: "photo")
                }
                .accessibilityIdentifier("qe-photo")
                if cameraAvailable {
                    Button { showCamera = true } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    .accessibilityIdentifier("qe-camera")
                }
            }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: index) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .offset(x: 4, y: -4)
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func loadPlace() async {
        loadingPlace = true
        placeError = nil
        defer { loadingPlace = false }
        do {
            place = model.options.isDemo ? Place.demo : try await Place.current()
        } catch {
            placeError = error.localizedDescription
        }
    }

    private func loadWeather() async {
        loadingWeather = true
        weatherError = nil
        defer { loadingWeather = false }
        do {
            weather = model.options.isDemo ? Weather.demo : try await Weather.current()
        } catch {
            weatherError = error.localizedDescription
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        defer { photoItems = [] }
        for item in items {
            guard images.count < maxPhotos else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            images.append(image)
        }
    }

    // MARK: Dictation

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        dictationBase = text.isEmpty ? "" : text + " "
        error = nil
        Task {
            do {
                try await dictation.start { [dictationBase] transcript in
                    text = dictationBase + transcript
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Save

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && mood == nil
    }

    private func save() {
        var lines: [String] = ["# \(headerDate)"]
        if let place { lines.append("- 📍 Place: \(place)") }
        if let weather { lines.append(weather.line) }
        if let mood, let moodList { lines.append(moodList.line(for: mood)) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("")
            lines.append(trimmed)
        }
        for image in images {
            if let markdown = try? model.addImage(image, alt: "Photo") {
                lines.append("")
                lines.append(markdown)
            }
        }
        do {
            try model.save(text: lines.joined(separator: "\n"), id: nil)
            saved = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var headerDate: String {
        let day = date.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).year())
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time)"
    }
}
