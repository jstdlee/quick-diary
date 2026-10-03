import SwiftUI

/// Collect today's facts into the note: weather, reminders done, calendar, photos.
/// Nothing is read until the user taps a section; nothing is added until "Add to note".
struct TodaySheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ai: AISettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var today: TodayModel
    var append: (String) -> Void

    @State private var weather: Weather.Now?
    @State private var weatherError: String?
    @State private var loadingWeather = false
    @State private var pickedReminders: Set<String> = []
    @State private var pickedEvents: Set<String> = []
    @State private var pickedPhotos: Set<String> = []
    @State private var summary: AIRequest?
    @State private var adding = false

    init(demo: Bool, append: @escaping (String) -> Void) {
        _today = StateObject(wrappedValue: TodayModel(demo: demo))
        self.append = append
    }

    var body: some View {
        NavigationStack {
            List {
                weatherSection
                remindersSection
                calendarSection
                photosSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .task {
                await today.loadGranted()
                pickedReminders = Set(today.reminders)
                pickedEvents = Set(today.events.map(\.id))
            }
            .sheet(item: $summary) { request in
                AIResultSheet(request: request) { text in
                    append("### Summary\n\(text)")
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Sections

    private var weatherSection: some View {
        Section("Weather") {
            if let weather {
                Toggle(isOn: Binding(get: { self.weather != nil }, set: { if !$0 { self.weather = nil } })) {
                    Text(weather.line.dropFirst(2))
                }
            } else {
                Button(action: loadWeather) {
                    HStack {
                        Label("Add the current weather", systemImage: "cloud.sun")
                        Spacer()
                        if loadingWeather { ProgressView() }
                    }
                }
                .accessibilityIdentifier("todayWeather")
                if let weatherError { Text(weatherError).font(.footnote).foregroundStyle(.red) }
            }
        }
    }

    private var remindersSection: some View {
        Section {
            switch today.remindersAccess {
            case .unknown:
                allowButton("Show reminders you completed", symbol: "checklist") { await today.allowReminders(); pickedReminders = Set(today.reminders) }
            case .denied:
                deniedText("Reminders")
            case .granted:
                if today.reminders.isEmpty {
                    Text("No reminders completed today.").foregroundStyle(.secondary)
                }
                ForEach(today.reminders, id: \.self) { title in
                    pickRow(title, picked: pickedReminders.contains(title)) { toggle(&pickedReminders, title) }
                }
            }
        } header: {
            Text("Done today")
        }
    }

    private var calendarSection: some View {
        Section {
            switch today.calendarAccess {
            case .unknown:
                allowButton("Show today's calendar", symbol: "calendar") { await today.allowCalendar(); pickedEvents = Set(today.events.map(\.id)) }
            case .denied:
                deniedText("Calendars")
            case .granted:
                if today.events.isEmpty {
                    Text("Nothing on the calendar today.").foregroundStyle(.secondary)
                }
                ForEach(today.events) { event in
                    pickRow("\(event.time)  \(event.title)", picked: pickedEvents.contains(event.id)) {
                        toggle(&pickedEvents, event.id)
                    }
                }
            }
        } header: {
            Text("Calendar")
        }
    }

    private var photosSection: some View {
        Section {
            switch today.photosAccess {
            case .unknown:
                allowButton("Show photos taken today", symbol: "photo.on.rectangle") { await today.allowPhotos() }
            case .denied:
                deniedText("Photos")
            case .granted:
                if today.photos.isEmpty {
                    Text("No photos taken today.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(today.photos) { photo in
                            photoCell(photo)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Photos")
        } footer: {
            Text("Picked photos are added as encrypted attachments.")
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(action: addToNote) {
                HStack {
                    if adding { ProgressView().tint(.white) }
                    Text(addTitle).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pickedCount == 0 || adding)
            .accessibilityIdentifier("todayAdd")

            Button { summary = dayRequest } label: {
                Label("Summarize my day", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(ai.engine == nil || pickedCount == 0)
            .accessibilityIdentifier("todaySummarize")
            Text(ai.engine.map { String(localized: "AI: \($0.destination)") } ?? ai.disabledReason ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }

    // MARK: Helpers

    private var pickedCount: Int {
        pickedReminders.count + pickedEvents.count + pickedPhotos.count + (weather == nil ? 0 : 1)
    }

    private var addTitle: String {
        pickedCount == 1 ? String(localized: "Add 1 item to note") : String(localized: "Add \(pickedCount) items to note")
    }

    private func allowButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Label(title, systemImage: symbol) }
    }

    private func deniedText(_ app: String) -> some View {
        Text("Quick Diary can't read \(app). Allow it in the Settings app › Privacy & Security › \(app).")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func pickRow(_ title: String, picked: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                Text(title).foregroundStyle(.primary)
            }
        }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func photoCell(_ photo: TodayPhoto) -> some View {
        let picked = pickedPhotos.contains(photo.id)
        return Button { toggle(&pickedPhotos, photo.id) } label: {
            Image(uiImage: photo.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(Color.white, picked ? Color.accentColor : Color.black.opacity(0.3))
                        .padding(4)
                }
                .opacity(picked ? 1 : 0.85)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Photo"))
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("todayPhoto")
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func loadWeather() {
        loadingWeather = true
        weatherError = nil
        Task {
            defer { loadingWeather = false }
            do {
                if model.options.isDemo {
                    weather = Weather.demo
                } else {
                    weather = try await Weather.current()
                }
            } catch {
                weatherError = error.localizedDescription
            }
        }
    }

    /// The picked facts as Markdown lines (photos excluded).
    private var factLines: [String] {
        var lines: [String] = []
        if let weather { lines.append(weather.line) }
        let done = today.reminders.filter(pickedReminders.contains)
        if !done.isEmpty { lines.append(contentsOf: done.map { "- [x] \($0)" }) }
        let events = today.events.filter { pickedEvents.contains($0.id) }
        lines.append(contentsOf: events.map { "- 📅 \($0.time) \($0.title)" })
        return lines
    }

    private func addToNote() {
        adding = true
        Task {
            defer { adding = false }
            var lines = ["## Today"] + factLines
            for photo in today.photos where pickedPhotos.contains(photo.id) {
                if let image = await photo.full(), let line = try? model.addImage(image, alt: "Photo") {
                    lines.append(line)
                }
            }
            append(lines.joined(separator: "\n"))
            dismiss()
        }
    }

    private var dayRequest: AIRequest? {
        guard let engine = ai.engine else { return nil }
        let picked = today.photos.filter { pickedPhotos.contains($0.id) }
        return AIRequest(title: String(localized: "Summary of today"), engine: engine,
                         instructions: AIPrompts.summarizeDay,
                         prompt: factLines.joined(separator: "\n"),
                         images: engine.supportsImages ? picked.compactMap { AISettings.jpegForAI($0.thumbnail) } : [])
    }
}
