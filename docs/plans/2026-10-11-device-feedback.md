# Device feedback 2026-10-11: implementation guide

Feedback from the first real-iPhone test. Do the work packages (WP) in order. Build after each WP.
Do not commit. Do not touch `project.yml` sections that are not named here.

## Build and test loop (Linux → Mac)

The repo is on Linux at `~/dev/quick-diary`. Swift builds only on the Mac (`ssh mac`).

```bash
# sync (from ~/dev/quick-diary)
rsync -az --delete --exclude .git --exclude build --exclude DerivedData ./ mac:dev/jev/quick-diary/
# build (fast check, ~2-4 min)
ssh mac 'cd ~/dev/jev/quick-diary && export PATH=$HOME/bin:$PATH && xcodegen generate -q && xcodebuild -project QuickDiary.xcodeproj -scheme QuickDiary -destination "generic/platform=iOS Simulator" -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|warning: .*QuickDiary/|BUILD (SUCCEEDED|FAILED)" | tail -30'
```

- Never run two `xcodebuild` at once: the Mac has 8 GB RAM.
- Deployment target is **iOS 17.0**. Every API must exist on iOS 17, or be wrapped in `if #available`.
- Keep the code style: short `///` doc comments, `String(localized:)` for user text, `accessibilityIdentifier` on
  everything a UI test taps, SF Symbols, `.sensoryFeedback` for haptics.
- `LaunchOptions.isDemo` (UI tests, `-demo`) must never touch location, network, microphone or speech.
  Return fixed demo values instead, as `Weather.demo` does.

## WP1: One editor bar (feedback 1) + Location and Date/time (feedback 3)

**Problem.** In edit mode two bars show at the same time: the keyboard toolbar
(`ToolbarItemGroup(placement: .keyboard)` in `EditorView`, with Heading/List/Checkbox/Quote/Done) and
`CaptureBar` (Today, Mood, Meal, Sport, Weather, Photo, Camera, Scan) in `.safeAreaInset(edge: .bottom)`.
On iOS 17 they overlap.

**Goal.** One bar only. Remove the `.keyboard` toolbar group. `CaptureBar` becomes the single editor bar.
`.safeAreaInset(edge: .bottom)` already rides above the keyboard, so the bar sits on the keyboard when it is up,
and at the bottom when it is down.

Bar layout, left to right (horizontal `ScrollView` as now, chips stay the same style):

1. **Format** chip (`textformat`): `Menu` with Heading `# `, List `- `, Checkbox `- [ ] `, Quote `> `.
   Uses the existing `insertLine` behaviour (new line at the end; TextEditor has no cursor API before iOS 18).
   Pass it in as a closure, e.g. `insertMarker: (String) -> Void`.
2. One chip per quick list (Mood, Meal, Sport, …): `Menu` as now.
3. **Insert** chip (`plus.circle`): one `Menu` with cascading entries:
   - Date & time → `- 🕒 Sat, 11 Oct 2026 at 17:20` (`Date.now.formatted(date: .complete … )`; pick a
     compact, locale-aware format, weekday + date + time).
   - Location → `- 📍 Place, City` (see below).
   - Weather (existing `addWeather`).
   - Today… (existing Today sheet).
   - `Divider()`
   - Photo library, Camera (if available), Scan document (if available).
   A `PhotosPicker` cannot live inside a `Menu`; use a Button that sets `showPhotoPicker = true` and
   `.photosPicker(isPresented:selection:matching:)` on the bar.
4. Spacer, then a **Done** button (`keyboard.chevron.compact.down`, label "Hide keyboard") shown only while the
   editor has focus. `EditorView` passes its focus state in (Binding or closure).

Keep the busy spinner on the Insert chip while weather, location, photo or scan work.
Accessibility identifiers: `bar-format`, `bar-insert`, `quick-<list name>` (keep), `insert-datetime`,
`insert-location`, `insert-weather`, `insert-today`, `insert-photo`, `insert-camera`, `insert-scan`, `bar-done`.
Keep `quick-Today` and `quick-Weather` working or update `QuickDiaryUITests/ScreenshotTests.swift` to the new ids.

**Location.** Add to `Core/Weather.swift` (or a new `Core/Place.swift`):

```swift
enum Place {
    static let demo = "Demo Street, Demo City"
    /// "Name, City" from one ~100 m fix. Only Apple's geocoder sees the location.
    @MainActor static func current() async throws -> String
}
```

Use `LocationFetcher` (add an `accuracy` parameter; Place needs `kCLLocationAccuracyHundredMeters`, Weather keeps
1 km). Reverse geocode with `CLGeocoder`; join `name` (or `thoroughfare`) and `locality`, skip empties, fall back
to `"lat, lon"` rounded to 3 decimals. Update `NSLocationWhenInUseUsageDescription` in `project.yml` to cover both
weather and location, e.g. "Add the weather or your current place to a note. Location is used only when you tap
Weather or Location."

`LocationFetcher.Denied` text mentions weather only; make it generic ("…to add your place or the weather").

## WP2: Appearance changes at once (feedback 4)

**Problem.** Settings › Appearance changes `@AppStorage("appearance")`, but `preferredColorScheme` on the root
view does not reach the presented Settings sheet until it closes (SwiftUI sheets keep their own trait).

**Fix.** Apply the style to the UIKit windows, which updates every presented sheet immediately:

```swift
extension Appearance {
    var uiStyle: UIUserInterfaceStyle { switch self { case .system: .unspecified; case .light: .light; case .dark: .dark } }
    @MainActor func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = uiStyle }
        }
    }
}
```

Call `appearance.apply()` in `QuickDiaryApp` on `.task`/`.onAppear` and in `.onChange(of: appearance)`.
Keep `.preferredColorScheme` too (it drives the first frame). Check that switching back to System works.
Also wrap the change in `withAnimation(.easeInOut(duration: 0.25))` only if it does not flicker; otherwise none.

## WP3: Home Screen quick action → Quick entry sheet (feedback 5)

**User story.** Long-press the app icon → "Quick entry". The app opens (unlock first if locked; Face ID makes
this fast) and shows a **Quick entry** sheet over the notes list. One screen, thumb-friendly:

- Header row: date & time (auto, editable via `DatePicker` compact), place (auto-fetched, chip with ✕ to drop it),
  weather (auto-fetched, chip with ✕). Auto-fetch starts when the sheet opens; show a small spinner per chip;
  on error the chip shows "Add place" / "Add weather" to retry. Demo mode uses `Place.demo` / `Weather.demo`.
- Mood: one row of emoji buttons from the quick list named "Mood" (`QuickListStore`), single select, tap again
  to clear. If there is no "Mood" list, use the defaults' options.
- Text: multi-line `TextField(axis: .vertical)` with `lineLimit(4...10)`, focused on open.
- Voice: a mic button that dictates into the text field (Speech framework, `SFSpeechRecognizer` +
  `AVAudioEngine`; `requiresOnDeviceRecognition = true` when `supportsOnDeviceRecognition`). Tap to start, tap to
  stop; show a pulsing red dot while it listens. Append the transcript to the text. Add
  `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` to `project.yml`
  (say speech is turned into text on the iPhone when possible, and the audio is not saved).
  Hide the mic in demo mode.
- Images: Photo library (multi-select up to 5) and Camera buttons; thumbnails in a row, tap ✕ to remove.
- Toolbar: Cancel (left), **Save** (right, `.confirmationAction`, disabled when everything is empty).

**Save** builds one Markdown note and saves it with `model.save(text:id: nil)`; images via `model.addImage`:

```markdown
# Sat, 11 Oct 2026 · 17:20
- 📍 Place: Demo Street, Demo City
- ⛅ Weather: 18°C · Partly cloudy · Demo City
- Mood: 🙂 Good

The text…

![Photo](attachments/…)
```

Reuse `Weather.Now.line` and `QuickList.line(for:)` so lines match the editor's quick entries.
After save: dismiss, success haptic, and the new note is first in the list (do not open the editor).

**Plumbing.**

- `project.yml` › `info.properties` › `UIApplicationShortcutItems`:
  - `UIApplicationShortcutItemType: com.jstdlee.quickdiary.quick-entry`, title "Quick entry",
    `UIApplicationShortcutItemIconSymbolName: bolt.fill` (SF Symbol key).
  - `…new-note`, title "New note", symbol `square.and.pencil` (opens the editor, as the Shortcut does now).
- Add `@UIApplicationDelegateAdaptor` `AppDelegate` that returns a `UISceneConfiguration` with a `SceneDelegate`
  (`UIWindowSceneDelegate`). Handle both a cold start (`connectionOptions.shortcutItem` in
  `scene(_:willConnectTo:options:)`) and a warm start (`windowScene(_:performActionFor:completionHandler:)`).
  Both set a request on a `@MainActor` shared place (like `IntentRequests`) and post a notification; the app
  then sets `model.pendingQuickEntry = true` (new `@Published` on `AppModel`, next to `pendingNewEntry`).
  Do not break the existing `NewEntryIntent` path.
- `NotesListView` presents `QuickEntrySheet` when `model.pendingQuickEntry` becomes true (and on appear, since
  the request can arrive before unlock), then clears it.
- New file `QuickDiary/Views/QuickEntrySheet.swift`; speech helper in `QuickDiary/Core/Dictation.swift`.
- Launch flag `-quickEntry` (demo only) opens the sheet after unlock, for UI tests.

Accessibility ids: `quickEntrySheet`, `qe-text`, `qe-mood-<index>`, `qe-place`, `qe-weather`, `qe-date`,
`qe-mic`, `qe-photo`, `qe-camera`, `qe-save`, `qe-cancel`.

## WP4: Screenshot tour (feedback 6)

Extend `QuickDiaryUITests/ScreenshotTests.swift` (iPhone and iPad):

- In the editor: shot with keyboard up showing the single bar (`07c-editor-bar`); open the Format menu
  (`07d-format-menu`); open the Insert menu (`07e-insert-menu`); tap Date & time and Location, then shot
  (`07f-inserted-place-time`).
- Settings: switch Appearance to Dark while Settings is open and shoot before closing (`12b-settings-dark`),
  then back to System.
- Quick entry: launch with `-demo -quickEntry`, unlock, wait for `quickEntrySheet`, pick a mood, type text,
  shoot (`23-quick-entry`), Save, shoot the list (`24-after-quick-entry`).

Run the full suite only at the end (`scripts/ci-test.sh`, ~10 min). Report pass/fail counts and the list of
screenshots.

## Done means

- Simulator build has no errors and no new warnings in our files.
- `scripts/ci-test.sh` passes on the Mac (iPhone 17 Pro + iPad Pro 11).
- A short report: what changed per WP, files touched, anything not done and why.
