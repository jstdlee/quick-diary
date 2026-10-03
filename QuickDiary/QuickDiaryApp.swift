import SwiftUI

@main
struct QuickDiaryApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(appearance.colorScheme)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Lock when the app goes to the background. Editors save on .inactive first.
                    if phase == .background && !model.options.isDemo { model.lock() }
                }
        }
    }
}

/// Settings › Appearance. `-appearance dark` on the command line sets it for screenshots.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
