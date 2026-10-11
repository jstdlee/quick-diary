#!/usr/bin/env python3
"""Build a screenshot review page (build/review/index.html + JPEGs) from build/mac-screens/*.png.

Usage: python3 scripts/review-page.py <build-label>
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "build" / "mac-screens"
OUT = ROOT / "build" / "review"
LABEL = sys.argv[1] if len(sys.argv) > 1 else "build"

TITLES = {
    "01-create-password": "Create a password",
    "02-recovery-key": "Recovery key",
    "03-no-notes": "No notes yet",
    "04-locked": "Locked",
    "05-wrong-password": "Wrong password",
    "06-notes": "Notes list",
    "07-editor": "Editor",
    "07b-ai-summary": "AI summary",
    "07c-editor-bar": "Editor bar on the keyboard",
    "07d-format-menu": "Format menu",
    "07e-insert-menu": "Insert menu",
    "07f-inserted-place-time": "Date & time and place inserted",
    "08-preview-with-photo": "Preview with photo",
    "09-new-note-capture-bar": "New note with quick entries",
    "09a-today": "Today sheet",
    "09b-day-summary": "Day summary",
    "10-notes-after-new": "Notes after a new note",
    "11-recently-deleted": "Recently Deleted",
    "12-settings": "Settings",
    "12b-settings-dark": "Settings switched to Dark (sheet open)",
    "13-attachments": "Attachments",
    "13b-ai-settings": "AI settings",
    "13c-backup": "Backup",
    "14-quick-entries": "Quick entries editor",
    "15-help": "Help",
    "16-privacy": "Privacy",
    "17-password-changed": "Password changed",
    "18-recovery-key": "Show recovery key",
    "20-dark-large-locked": "Dark + large text: locked",
    "21-dark-large-notes": "Dark + large text: notes",
    "22-dark-large-preview": "Dark + large text: preview",
    "23-quick-entry": "Quick entry sheet",
    "24-after-quick-entry": "Notes after Quick entry",
}
NEW = {"07c-editor-bar", "07d-format-menu", "07e-insert-menu", "07f-inserted-place-time",
       "12b-settings-dark", "23-quick-entry", "24-after-quick-entry"}

OUT.mkdir(parents=True, exist_ok=True)
shots = []
for png in sorted(SRC.glob("*.png")):
    device, key = png.stem.split("-", 1)
    jpg = OUT / "shots" / f"{png.stem}.jpg"
    jpg.parent.mkdir(exist_ok=True)
    subprocess.run(["convert", str(png), "-resize", "x1400>", "-quality", "82", str(jpg)], check=True)
    shots.append({"id": png.stem, "device": device, "key": key,
                  "title": TITLES.get(key, key), "new": key in NEW, "src": f"shots/{jpg.name}"})

template = (ROOT / "scripts" / "review-page.html").read_text()
html = template.replace("__SHOTS__", json.dumps(shots)).replace("__LABEL__", LABEL)
(OUT / "index.html").write_text(html)
print(f"{len(shots)} shots -> {OUT / 'index.html'}")
