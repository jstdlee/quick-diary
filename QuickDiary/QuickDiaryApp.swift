import SwiftUI

@main
struct QuickDiaryApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Lock when the app goes to the background. Editors save on .inactive first.
                    if phase == .background && !model.options.isDemo { model.lock() }
                }
        }
    }
}
