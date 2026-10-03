#!/usr/bin/env python3
"""Print the UDID of an available simulator (iPhone, or iPad with `ipad`) on the newest iOS runtime."""
import json
import re
import subprocess
import sys

family = "iPad" if len(sys.argv) > 1 and sys.argv[1].lower() == "ipad" else "iPhone"
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if not d["name"].startswith(family):
            continue
        # Prefer a plain current model ("iPhone 16", "iPad Pro 11-inch") over Plus/Max/mini/SE.
        if family == "iPhone":
            plain = 1 if re.fullmatch(r"iPhone \d+( Pro)?", d["name"]) else 0
        else:
            plain = 1 if "11-inch" in d["name"] else 0
        key = (version, plain, d["name"])
        if best is None or key > best[0]:
            best = (key, d["udid"], d["name"])
if best is None:
    sys.exit(f"no {family} simulator found")
print(f"{best[2]} iOS {best[0][0][0]}.{best[0][0][1]}", file=sys.stderr)
print(best[1])
