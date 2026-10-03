#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime."""
import json
import re
import subprocess
import sys

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if not d["name"].startswith("iPhone"):
            continue
        # Prefer a plain current model (e.g. "iPhone 16") over Plus/Pro Max/SE.
        plain = 1 if re.fullmatch(r"iPhone \d+( Pro)?", d["name"]) else 0
        key = (version, plain, d["name"])
        if best is None or key > best[0]:
            best = (key, d["udid"], d["name"])
if best is None:
    sys.exit("no iPhone simulator found")
print(f"{best[2]} iOS {best[0][0][0]}.{best[0][0][1]}", file=sys.stderr)
print(best[1])
