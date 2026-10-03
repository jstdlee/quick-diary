import SwiftUI

@main
struct QuickDiaryApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var quickLists = QuickListStore()
    @StateObject private var ai = AISettings()
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @AppStorage(LockAfter.storageKey) private var lockAfter = LockAfter.oneMinute
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(quickLists)
                .environmentObject(ai)
                .preferredColorScheme(appearance.colorScheme)
                // Hide notes in the app switcher and while Control Center or a call covers the app.
                .overlay {
                    if scenePhase != .active && model.phase == .unlocked && !model.options.isDemo {
                        PrivacyCover()
                    }
                }
                .task {
                    await model.start()
                    if IntentRequests.newEntry {
                        IntentRequests.newEntry = false
                        model.pendingNewEntry = true
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .quickDiaryNewEntry)) { _ in
                    IntentRequests.newEntry = false
                    model.pendingNewEntry = true
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: model.appDidEnterBackground()
                    case .active: model.appDidBecomeActive(lockAfter: lockAfter.seconds)
                    default: break
                    }
                }
        }
    }
}

/// Shown over the app when it is not active, so the app switcher shows no notes.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Settings › Lock after.
enum LockAfter: Int, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    static let storageKey = "lockAfter"

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .oneMinute: String(localized: "After 1 minute")
        case .fiveMinutes: String(localized: "After 5 minutes")
        case .fifteenMinutes: String(localized: "After 15 minutes")
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
