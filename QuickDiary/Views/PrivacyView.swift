import SwiftUI

/// Settings › Privacy: what stays on the device and what leaves it, in plain words.
struct PrivacyView: View {
    private struct Row: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let text: String
    }

    private let stays: [Row] = [
        Row(symbol: "lock.doc", title: "Notes and attachments",
            text: "Encrypted on this device with AES-256 before they are saved."),
        Row(symbol: "text.viewfinder", title: "Scanned text",
            text: "Recognized on this device. Nothing is uploaded."),
        Row(symbol: Biometrics.symbol, title: Biometrics.name,
            text: "The key is kept in this device's Keychain. Quick Diary never sees your face or fingerprint."),
        Row(symbol: "checklist", title: "Reminders, Calendar, Photos",
            text: "Read on this device when you open Today and allow it. Only what you pick goes into a note."),
        Row(symbol: "chart.bar.xaxis", title: "No analytics",
            text: "No accounts, no tracking, no Quick Diary servers."),
    ]

    private let leaves: [Row] = [
        Row(symbol: "folder", title: "Your storage",
            text: "Encrypted files go where you choose: this iPhone, iCloud Drive or a folder in Files."),
        Row(symbol: "cloud.sun", title: "Weather",
            text: "Only when you tap Weather: your location, rounded to about 1 km, goes to Open-Meteo."),
        Row(symbol: "sparkles", title: "AI on your server",
            text: "Only when you tap ✨ or Summarize: that note, or the facts and photos you picked, go to the server you set up. The on-device model sends nothing."),
        Row(symbol: "externaldrive.badge.icloud", title: "Backup",
            text: "Only when you tap Back up: the encrypted files go to your S3 or R2 bucket. The provider can't read them."),
        Row(symbol: "square.and.arrow.up", title: "Sharing",
            text: "Only when you tap Share: that note's text, as plain text, to the app you pick."),
    ]

    var body: some View {
        List {
            Section {
                Text("Quick Diary encrypts your notes on your device. There are no Quick Diary servers, no accounts and no analytics. Data leaves your device only when you use a feature that needs it.")
            }
            Section("Stays on this device") { ForEach(stays, content: row) }
            Section("Leaves only when you ask") { ForEach(leaves, content: row) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ row: Row) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                Text(row.text).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: row.symbol).foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
    }
}
