import EventKit
import Foundation
import Photos
import UIKit

struct TodayEvent: Identifiable, Hashable {
    let id: String
    let time: String
    let title: String
}

struct TodayPhoto: Identifiable {
    let id: String
    let thumbnail: UIImage
    let full: () async -> UIImage?
}

/// What happened today, from Reminders, Calendar and Photos. Read on the device only;
/// each permission is asked the first time the user taps that section.
@MainActor
final class TodayModel: ObservableObject {
    enum Access: Equatable { case unknown, granted, denied }

    @Published var reminders: [String] = []
    @Published var events: [TodayEvent] = []
    @Published var photos: [TodayPhoto] = []
    @Published var remindersAccess: Access
    @Published var calendarAccess: Access
    @Published var photosAccess: Access

    private let store = EKEventStore()
    let demo: Bool

    init(demo: Bool) {
        self.demo = demo
        if demo {
            remindersAccess = .granted
            calendarAccess = .granted
            photosAccess = .granted
        } else {
            remindersAccess = Self.access(EKEventStore.authorizationStatus(for: .reminder))
            calendarAccess = Self.access(EKEventStore.authorizationStatus(for: .event))
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized, .limited: photosAccess = .granted
            case .notDetermined: photosAccess = .unknown
            default: photosAccess = .denied
            }
        }
    }

    private static func access(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    private var startOfDay: Date { Calendar.current.startOfDay(for: Date()) }

    func loadGranted() async {
        if remindersAccess == .granted { await loadReminders() }
        if calendarAccess == .granted { loadEvents() }
        if photosAccess == .granted { await loadPhotos() }
    }

    // MARK: Reminders completed today

    func allowReminders() async {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        remindersAccess = granted ? .granted : .denied
        if granted { await loadReminders() }
    }

    private func loadReminders() async {
        if demo {
            reminders = ["Pay the electricity bill", "Book the dentist", "Water the plants"]
            return
        }
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: startOfDay,
                                                             ending: Date(), calendars: nil)
        let store = self.store
        let titles: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap(\.title))
            }
        }
        reminders = titles
    }

    // MARK: Calendar

    func allowCalendar() async {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        calendarAccess = granted ? .granted : .denied
        if granted { loadEvents() }
    }

    private func loadEvents() {
        if demo {
            events = [TodayEvent(id: "1", time: "09:30", title: "Team standup"),
                      TodayEvent(id: "2", time: "18:00", title: "Yoga")]
            return
        }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        let predicate = store.predicateForEvents(withStart: startOfDay, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                TodayEvent(id: event.eventIdentifier ?? UUID().uuidString,
                           time: event.isAllDay ? String(localized: "All day")
                               : event.startDate.formatted(date: .omitted, time: .shortened),
                           title: event.title ?? String(localized: "Event"))
            }
    }

    // MARK: Photos taken today

    func allowPhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photosAccess = (status == .authorized || status == .limited) ? .granted : .denied
        if photosAccess == .granted { await loadPhotos() }
    }

    private func loadPhotos() async {
        if demo {
            let palettes: [[UIColor]] = [[.systemYellow, .systemOrange], [.systemGreen, .systemTeal],
                                         [.systemPurple, .systemBlue]]
            photos = palettes.enumerated().map { index, colors in
                let image = DemoData.image(size: CGSize(width: 1200, height: 900), colors: colors,
                                           label: ["Breakfast", "Park", "Sunset"][index])
                return TodayPhoto(id: "demo-\(index)", thumbnail: image, full: { image })
            }
            return
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", startOfDay as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        var loaded: [TodayPhoto] = []
        for asset in assets.prefix(60) {
            guard let thumbnail = await Self.image(for: asset, side: 240) else { continue }
            loaded.append(TodayPhoto(id: asset.localIdentifier, thumbnail: thumbnail,
                                     full: { await Self.image(for: asset, side: 2048) }))
        }
        photos = loaded
    }

    private static func image(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
