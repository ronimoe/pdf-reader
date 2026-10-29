#!/bin/zsh
# Experiment 1: do security-scoped bookmarks survive an ad-hoc rebuild, and follow a moved file?
#
#  1. Build v1, open a fresh PDF with `open -a v1.app file.pdf` (LaunchServices grants the extension).
#  2. v1 stores a security-scoped bookmark in its container.
#  3. Control: relaunch v1 without the file and resolve (same signature).
#  4. Build v2 (code change, new CDHash), relaunch without the file and resolve.
#  5. Move the file, resolve again with v2.
# Every resolve run first tries a plain open(2) of the path, which the sandbox must deny.
source "${0:A:h}/lib.sh"
kill_probes
rm -rf "$FIXTURES"
pdf="$FIXTURES/bookmark-test.pdf"
make_pdf "$pdf"
xattr -c "$pdf"

V1=$BUILD_ROOT/v1/PlatformProbe.app
V2=$BUILD_ROOT/v2/PlatformProbe.app
[[ -d $V1 ]] || build_probe v1 >/dev/null
[[ -d $V2 ]] || build_probe v2 >/dev/null
say "signatures"; sig_info "$V1"; sig_info "$V2"

say "step 1-2: v1 opens the file through LaunchServices and stores a bookmark"
run_probe "$V1" bm-1-create-v1 20 "$pdf" --mode bookmark-create
logs_since "$LAST_LAUNCH_TS" bm-1-create-v1

say "step 3 (control): v1 relaunched without the file"
run_probe "$V1" bm-2-resolve-v1 20 "" --mode bookmark-resolve --direct-path "$pdf"

say "step 4: v2 (different CDHash) launched without the file"
run_probe "$V2" bm-3-resolve-v2 20 "" --mode bookmark-resolve --direct-path "$pdf"
logs_since "$LAST_LAUNCH_TS" bm-3-resolve-v2

say "step 5a: rename the file in place, resolve with v2"
mv "$pdf" "$FIXTURES/renamed.pdf"
run_probe "$V2" bm-4-renamed-v2 20 "" --mode bookmark-resolve --direct-path "$FIXTURES/renamed.pdf"

say "step 5b: move the file into another folder, resolve with v2"
mkdir -p "$FIXTURES/moved/deeper"
mv "$FIXTURES/renamed.pdf" "$FIXTURES/moved/deeper/moved.pdf"
run_probe "$V2" bm-5-moved-v2 20 "" --mode bookmark-resolve --direct-path "$FIXTURES/moved/deeper/moved.pdf"

say "step 5c: back to v1 after v2 refreshed or used the bookmark"
run_probe "$V1" bm-6-resolve-v1-again 20 "" --mode bookmark-resolve --direct-path "$FIXTURES/moved/deeper/moved.pdf"

kill_probes
