import Foundation
import UIKit

/// Sample notes for screenshots and UI tests (`-demo`). Never touches real notes.
enum DemoData {
    static let notes: [(hoursAgo: Double, text: String)] = [
        (1.5, """
        # Morning run

        - 📍 Riverside loop
        - 🏃 5.2 km · 28 min

        Cool air, legs felt light. **New best** on the hill.

        - [x] Stretch
        - [ ] Log shoe mileage
        """),
        (26, """
        # Ideas for Quick Diary

        1. Widget that opens straight to a new note
        2. Face ID unlock
        3. Search inside encrypted notes

        > Keep it small and fast.
        """),
        (50, """
        # Weekend plan

        - Farmers market
        - Call Mom
        - Finish *The Dispossessed*
        """),
        (98, """
        # Reading notes

        *The Pragmatic Programmer*, chapter 2

        `Don't repeat yourself` is about knowledge, not only code.

        ```
        one fact → one place
        ```
        """),
    ]

    static func seed(in folder: URL, password: String, iterations: Int) throws {
        let master = VaultCrypto.newMasterKey()
        let keyFile = try VaultCrypto.makeKeyFile(masterKey: master, password: password, iterations: iterations)
        try KeyFileIO.write(keyFile, in: folder)
        let store = NoteStore(folder: folder, key: master)
        let assets = AssetStore(folder: folder, key: master)
        let sunrise = try assets.add(image(size: CGSize(width: 1600, height: 1000),
                                           colors: [UIColor.systemOrange, UIColor.systemPink, UIColor.systemIndigo],
                                           label: "Riverside, 7:05"))
        _ = try assets.add(image(size: CGSize(width: 900, height: 1200),
                                 colors: [UIColor.systemTeal, UIColor.systemBlue], label: "Receipt"))
        for (index, sample) in notes.enumerated() {
            let date = Date().addingTimeInterval(-sample.hoursAgo * 3600)
            let text = index == 0 ? sample.text + "\n\n![Sunrise on the run](\(sunrise))" : sample.text
            let note = try store.save(text: text, id: nil, now: date)
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: folder.appendingPathComponent(note.id).path)
        }
        // Waiting in the inbox, as if added by Shortcuts while locked.
        let now = Date()
        try Inbox.add(InboxItem(date: now.addingTimeInterval(-3 * 3600), text: "8,214 steps · slept 7 h 10 min",
                                source: "Health"), folder: folder, keyFile: keyFile)
        try Inbox.add(InboxItem(date: now.addingTimeInterval(-2 * 3600), text: "Edited \"Groceries\" and \"Trip ideas\"",
                                source: "Apple Notes"), folder: folder, keyFile: keyFile)
    }

    /// A gradient picture with a label, standing in for a photo.
    static func image(size: CGSize, colors: [UIColor], label: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors.map(\.cgColor) as CFArray, locations: nil)!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.width / 14, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ]
            (label as NSString).draw(at: CGPoint(x: size.width * 0.06, y: size.height * 0.78), withAttributes: attributes)
        }
    }
}
