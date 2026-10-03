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
- Locks itself when the app goes to the background.

## How the encryption works

```
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
