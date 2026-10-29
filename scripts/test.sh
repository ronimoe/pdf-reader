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

if [[ $result -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED (logs in build/logs)"; fi
exit $result
