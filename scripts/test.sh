#!/bin/zsh
# Runs every test suite headlessly. Exit code is non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
echo "== swift test (LecternKit)"
(cd Packages/LecternKit && swift test 2>&1 | grep -E "^(✔|✘|◇ Test run)|error:|Test run with" | grep -v "◇ Test run started" || true)
(cd Packages/LecternKit && swift test >/dev/null 2>&1) || { echo "LecternKit tests FAILED"; exit 1; }

echo "== xcodebuild test (Lectern app)"
xcodebuild -project Lectern.xcodeproj -scheme Lectern -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData test 2>&1 \
  | grep -v "\[Connection\]" | grep -E "error:|✘|Test run with|TEST SUCCEEDED|TEST FAILED" || true
xcodebuild -project Lectern.xcodeproj -scheme Lectern -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData test >/dev/null 2>&1 || { echo "App tests FAILED"; exit 1; }
echo "ALL TESTS PASSED"
