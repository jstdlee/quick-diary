# Quick Diary

A small SwiftUI app for iPhone and iPad: encrypted Markdown notes in a folder you choose.

- **Markdown editor** with a preview (headings, lists, checkboxes, quotes, code, bold/italic/links).
- **Encrypted at rest.** Each note is a file `2026-10-03_1432.md.enc` (AES-256-GCM). The folder never holds plain text.
- **Choose where notes live** (Settings › Storage):
  - **On this iPhone** — Files › On My iPhone › Quick Diary
  - **iCloud Drive** — iCloud Drive › Quick Diary (needs a signed build, see below)
  - **Folder…** — any folder in Files, including shared iCloud Drive folders and other providers
- **Password + key.** A random 256-bit master key encrypts the notes. Your password unlocks the key file.
- **Change password** — only the key file is rewritten. Notes are not re-encrypted, so it's instant.
- **Recovery key** — shown once at setup, and again in Settings with your password. It can set a new password if you forget the old one, or if the key file is lost.
- **Key backup** — Settings › Back up key file exports `quick-diary-key.json`. It is still protected by your password.
- **Quick capture bar** under the editor, in thumb reach:
  - your own quick-entry menus (Mood, Meal, Sport, or any list of options)
  - Weather (Open-Meteo)
  - Photo, Camera
  - Scan (document camera plus on-device text recognition)
- **Encrypted attachments** in `assets/`. Deleting a note keeps them. Settings › Attachments lists them largest first and deletes only after you confirm.
- **Face ID / Touch ID** unlock, **Lock after** 0 / 1 / 5 / 15 minutes, and a cover in the app switcher.
- **Shortcuts and Siri:**
  - **New Quick Diary entry**
  - **Add to Quick Diary.** It works while the app is locked: the text is encrypted at once with the vault's public key and shows in a "From Shortcuts" note after you unlock. Use it to bring in Apple Notes ("Find Notes"), Health ("Find Health Samples") or anything Shortcuts can read.
- **Today** (a chip in the capture bar): the weather, reminders you completed, today's calendar and today's photos. Each permission is asked the first time you tap that section, and you pick what goes into the note.
- **AI**, Off by default:
  - Apple's on-device model (iOS 26, Apple Intelligence), or your own OpenAI-compatible server (OpenAI, OpenRouter, Ollama, llama.cpp, vLLM…) with the key in the Keychain.
  - Summarize a note, suggest a title, or summarize your day from Today.
  - Every answer is shown before it goes into a note, with how much text is sent and where.
- **Backup:**
  - S3 / R2 (SigV4). Only new and changed files are uploaded, and "Restore missing files" never replaces anything.
  - An encrypted **.zip** for Mail, Gmail, Files or AirDrop.
  - The storage provider sees only encrypted files, plus their names and sizes.
- **Photo strip** while editing: tap a thumbnail to view it, touch and hold to remove it from the note. The attachment itself stays.
- **Recently Deleted** keeps notes for 30 days.
- **Privacy page.** No servers, no accounts, no analytics. Weather sends a location rounded to about 1 km, and only when you tap it.

## How the encryption works

```
Shortcuts (locked) ──X25519 + HKDF + AES-GCM──▶ inbox/*.qdin ──(private key, sealed by master key)──▶ note at unlock
password ──PBKDF2-SHA256 (600,000 rounds, random salt)──▶ key-encryption key
                                                           │ AES-256-GCM
master key (random 256-bit) ◀──────── quick-diary-key.json ┘
   │ AES-256-GCM
   ▼
2026-10-03_1432.md.enc   = "QDN1" + nonce + ciphertext + tag
```

- Changing the password re-wraps the master key with a new salt. Notes stay as they are.
- The recovery key is the master key, written as 16 groups of 4 hex digits. Anyone who has it can read the notes.
- The key file also stores a 16-byte check value (HMAC of the master key). It lets a recovery key be checked without the password.
- A folder is a whole vault: the key file sits next to the notes. To move the vault, copy the folder.
- Switching storage copies the key file and notes to the new place. Nothing is moved or deleted.

## Install on an iPhone without a Mac

Every CI run uploads **QuickDiary-unsigned-ipa**:

```bash
gh run download -R jstdlee/quick-diary -n QuickDiary-unsigned-ipa
```

1. Download it with the command above.
2. Sign and install it with your free Apple ID, using [SideStore](https://sidestore.io), AltStore or Sideloadly.

A free Apple ID has these limits: the app must be re-signed every 7 days, iCloud Drive works only through **Folder…**, and Health works only through the Shortcuts bridge.

## Build

Xcode only runs on macOS. On Linux, use the GitHub Actions workflow.

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open QuickDiary.xcodeproj
```

### iCloud Drive

The iCloud option needs a device build signed by your Apple developer team. In Xcode, set the team and enable the iCloud capability (iCloud Documents, container `iCloud.com.jstdlee.quickdiary`). The entitlements are in `QuickDiary/QuickDiary.entitlements` and apply to device builds only.

Simulator and CI builds are unsigned, so they have no iCloud container. In those builds, **Folder…** still works with any iCloud Drive folder you pick in Files.

## Tests and screenshots

`scripts/ci-test.sh` (on macOS, and in CI on every push):

1. Generates the project.
2. Picks the newest iPhone simulator.
3. Runs the unit tests:
   - crypto: PBKDF2 known-answer vectors, wrong password, tampering, Unicode passwords, recovery key, password change
   - note store, Markdown parser
   - the app model's unlock, change-password and restore flow
4. Runs a UI test that walks through the app with demo data and saves screenshots to `screenshots/`.

The GitHub workflow uploads them as the **screenshots** artifact.

Launch flags for demos:

- `-demo` opens a seeded vault in a temp folder. The password is `demo1234`.
- `-demoFresh` opens an empty temp folder, which starts at "Create a password".

Both use fewer PBKDF2 rounds (20,000), so the tests stay fast. Real vaults use 600,000.
