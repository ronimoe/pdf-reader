#!/bin/zsh
# Runs every test suite headlessly, once each. Exit code is non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
result=0

xcodegen generate --quiet || exit 1

# The representative PDFs too large to commit (Tests/Corpus/public/fetched/): present ones are
# checked against their SHA-256, missing ones are downloaded and checked. Without them the corpus
# tests fail, so stop here with one clear message instead.
echo "== corpus: fetched files"
# Progress ("fetching <name>…") and errors go to the console; the rest to the log.
if ! scripts/corpus/bootstrap --fetch > build/logs/bootstrap-fetch.log; then
  echo "✘ The fetched test PDFs are missing and couldn't be downloaded (build/logs/bootstrap-fetch.log)."
  echo "  Run scripts/corpus/bootstrap --fetch, then run this script again."
  exit 1
fi

echo "== swift test (LecternKit)"
(cd Packages/LecternKit && LECTERN_REQUIRE_TOOLS=1 swift test) > build/logs/swift-test.log 2>&1 || result=1
grep -E "^✘|error:|Test run with" build/logs/swift-test.log

echo "== release scripts"
# sparkle-key.swift: a new key file is mode 600 even with a permissive umask, an existing one is
# never replaced, and `public` reads the same key back.
keydir=$(mktemp -d "${TMPDIR:-/tmp}/lectern-key-test.XXXXXX")
key_ok=1
pub=$( (umask 000; swift scripts/release/sparkle-key.swift generate "$keydir/k") 2>&1) || key_ok=0
[[ $(stat -f %Lp "$keydir/k" 2>/dev/null) == 600 ]] || { echo "✘ sparkle-key: key file mode is $(stat -f %Lp "$keydir/k" 2>/dev/null), expected 600"; key_ok=0; }
[[ $(swift scripts/release/sparkle-key.swift public "$keydir/k" 2>&1) == "$pub" ]] || { echo "✘ sparkle-key: public key doesn't match"; key_ok=0; }
before=$(shasum "$keydir/k")
swift scripts/release/sparkle-key.swift generate "$keydir/k" >/dev/null 2>&1 && { echo "✘ sparkle-key: replaced an existing key"; key_ok=0; }
[[ $(shasum "$keydir/k") == "$before" ]] || { echo "✘ sparkle-key: existing key changed"; key_ok=0; }
rm -rf "$keydir"
if (( key_ok )); then echo "✔ sparkle-key: mode 600 under umask 000, no overwrite, public key round-trips"; else result=1; fi

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
