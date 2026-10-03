#!/usr/bin/env bash
# Build, run unit + UI tests on a simulator, collect screenshots in ./screenshots.
# Runs on macOS (GitHub Actions or a Mac). Xcode is macOS-only.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

UDID=$(python3 scripts/pick-simulator.py)
rm -rf screenshots build/Result.xcresult
mkdir -p screenshots build

# TEST_RUNNER_ variables reach the test process without the prefix.
export TEST_RUNNER_SCREENSHOT_DIR="$PWD/screenshots"

set +e
xcodebuild test \
  -project QuickDiary.xcodeproj \
  -scheme QuickDiary \
  -destination "id=$UDID" \
  -resultBundlePath build/Result.xcresult \
  CODE_SIGNING_ALLOWED=NO 2>&1 \
  | tee build/xcodebuild.log \
  | grep -E --line-buffered '(error:|warning: .*QuickDiary|Test Case|Executed|\*\* )'
status=${PIPESTATUS[0]}
set -e

echo "Screenshots:"
ls -1 screenshots || true
exit "$status"
