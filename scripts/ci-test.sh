#!/usr/bin/env bash
# Build, run unit + UI tests on a simulator, collect screenshots in ./screenshots.
# Runs on macOS (GitHub Actions or a Mac). Xcode is macOS-only.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

IPHONE=$(python3 scripts/pick-simulator.py iphone)
IPAD=$(python3 scripts/pick-simulator.py ipad)
rm -rf screenshots build/Result.xcresult
mkdir -p screenshots build

# TEST_RUNNER_ variables reach the test process without the prefix.
export TEST_RUNNER_SCREENSHOT_DIR="$PWD/screenshots"

set +e
xcodebuild test \
  -project QuickDiary.xcodeproj \
  -scheme QuickDiary \
  -destination "id=$IPHONE" \
  -destination "id=$IPAD" \
  -resultBundlePath build/Result.xcresult \
  CODE_SIGNING_ALLOWED=NO 2>&1 \
  | tee build/xcodebuild.log \
  | grep -iE --line-buffered '(error:|warning: .*QuickDiary|test case .*(passed|failed)|Executed|\*\* )'
status=${PIPESTATUS[0]}
set -e

# Failure messages, readable without downloading the result bundle.
if [ "$status" -ne 0 ] && [ -d build/Result.xcresult ]; then
  xcrun xcresulttool get test-results summary --path build/Result.xcresult 2>/dev/null \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for f in d.get("testFailures", []):
    print("FAILED", f.get("targetName",""), f.get("testName",""), "::", f.get("failureText",""))' || true
fi

echo "Screenshots:"
ls -1 screenshots || true
exit "$status"
