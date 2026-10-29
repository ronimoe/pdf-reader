#!/bin/zsh
# Runs every test suite headlessly, once each. Exit code is non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
result=0

xcodegen generate --quiet || exit 1

echo "== swift test (LecternKit)"
(cd Packages/LecternKit && LECTERN_REQUIRE_TOOLS=1 swift test) > build/logs/swift-test.log 2>&1 || result=1
grep -E "^✘|error:|Test run with" build/logs/swift-test.log

echo "== xcodebuild test (Lectern app)"
xcodebuild -project Lectern.xcodeproj -scheme Lectern -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData test > build/logs/xcodebuild-test.log 2>&1 || result=1
grep -v "\[Connection\]" build/logs/xcodebuild-test.log | grep -E "error:|✘|Test run with|TEST SUCCEEDED|TEST FAILED"

# Offscreen snapshots (AppTests/M5/SnapshotTests.swift): the sandboxed test host writes them
# into its container's temporary folder; copy them where they can be looked at.
snapshots="$HOME/Library/Containers/io.github.ronimoe.Lectern/Data/tmp/LecternSnapshots"
if [[ -d $snapshots ]]; then
  rm -rf build/snapshots && mkdir -p build/snapshots
  cp "$snapshots"/*.png build/snapshots/ 2>/dev/null
  echo "== snapshots: $(ls build/snapshots | wc -l | tr -d ' ') PNGs in build/snapshots"
fi

if [[ $result -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED (logs in build/logs)"; fi
exit $result
