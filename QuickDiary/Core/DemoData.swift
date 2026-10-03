import Foundation

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
        for sample in notes {
            let date = Date().addingTimeInterval(-sample.hoursAgo * 3600)
            let note = try store.save(text: sample.text, id: nil, now: date)
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: folder.appendingPathComponent(note.id).path)
        }
    }
}
