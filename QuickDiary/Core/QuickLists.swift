import Foundation

/// A quick-entry menu in the editor: one tap on an option adds "- Name: option" to the note.
struct QuickList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String
    var options: [String]

    func line(for option: String) -> String { "- \(name): \(option)" }

    static let defaults: [QuickList] = [
        QuickList(name: "Mood", symbol: "face.smiling",
                  options: ["😄 Great", "🙂 Good", "😐 Okay", "🙁 Low", "😞 Bad"]),
        QuickList(name: "Meal", symbol: "fork.knife",
                  options: ["🍳 Breakfast", "🥗 Lunch", "🍝 Dinner", "🍪 Snack"]),
        QuickList(name: "Sport", symbol: "figure.run",
                  options: ["🏃 Run", "🚶 Walk", "🚴 Ride", "🏋️ Gym", "🧘 Yoga"]),
    ]

    /// SF Symbols offered for a list.
    static let symbols = ["face.smiling", "fork.knife", "figure.run", "cup.and.saucer", "bed.double",
                          "pills", "book", "music.note", "person.2", "briefcase", "cart", "star"]
}

/// Quick lists live in UserDefaults: they are labels, not diary content.
@MainActor
final class QuickListStore: ObservableObject {
    @Published var lists: [QuickList] { didSet { save() } }

    private static let key = "quickLists"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([QuickList].self, from: data) {
            lists = saved
        } else {
            lists = QuickList.defaults
        }
    }

    func resetToDefaults() { lists = QuickList.defaults }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(lists), forKey: Self.key)
    }
}
