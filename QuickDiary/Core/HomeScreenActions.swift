import UIKit

/// Shortcut item types for the two Home Screen quick actions (`project.yml` › `UIApplicationShortcutItems`).
enum QuickActionType {
    static let quickEntry = "com.jstdlee.quickdiary.quick-entry"
    static let newNote = "com.jstdlee.quickdiary.new-note"
}

/// `WindowGroup` has no hook for `UIApplicationShortcutItems`, so the app supplies its own
/// `UIWindowScene` delegate to receive them, both cold (`scene(_:willConnectTo:options:)`)
/// and warm (`windowScene(_:performActionFor:completionHandler:)`).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      configurationForConnecting connectingSceneSession: UISceneSession,
                      options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let shortcutItem = options.shortcutItem {
            Self.handle(shortcutItem)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                      completionHandler: @escaping (Bool) -> Void) {
        Self.handle(shortcutItem)
        completionHandler(true)
    }

    private static func handle(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case QuickActionType.quickEntry:
            IntentRequests.quickEntry = true
            NotificationCenter.default.post(name: .quickDiaryQuickEntry, object: nil)
        case QuickActionType.newNote:
            IntentRequests.newEntry = true
            NotificationCenter.default.post(name: .quickDiaryNewEntry, object: nil)
        default:
            break
        }
    }
}
