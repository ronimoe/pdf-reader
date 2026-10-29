#!/bin/zsh
# Experiment 3b: the same Keychain test, but v1 and v2 are re-signed ad-hoc with an
# explicit designated requirement that names only the bundle identifier, instead of
# the default ad-hoc requirement (`cdhash H"..."`), which changes with every build.
# Question: does the legacy keychain ACL then accept v2 without a prompt?
source "${0:A:h}/lib.sh"
# Interactive reads by v2 put a SecurityAgent prompt on screen; they only run with
# KC_INTERACTIVE=1 (the recorded runs in results/ had it set).
KC_INTERACTIVE=${KC_INTERACTIVE:-0}
kill_probes
SERVICE=io.github.ronimoe.PlatformProbe.m0c-test
REQ="=designated => identifier \"$BUNDLE_ID\""

resign() { # resign <src.app> <dest-tag>
  local src=$1 dest="$BUILD_ROOT/$2/PlatformProbe.app"
  rm -rf "$dest"; mkdir -p "${dest:h}"; ditto "$src" "$dest"
  local ent="$BUILD_ROOT/$2/entitlements.plist"
  codesign -d --entitlements - --xml "$src" > "$ent" 2>/dev/null
  codesign --force --sign - --options runtime --entitlements "$ent" --requirements "$REQ" "$dest" 2>&1
  print -r -- "$dest"
}
[[ -d $BUILD_ROOT/v1/PlatformProbe.app ]] || build_probe v1 >/dev/null
[[ -d $BUILD_ROOT/v2/PlatformProbe.app ]] || build_probe v2 >/dev/null
V1=$(resign "$BUILD_ROOT/v1/PlatformProbe.app" v1-iddr | tail -1)
V2=$(resign "$BUILD_ROOT/v2/PlatformProbe.app" v2-iddr | tail -1)
say "signatures"; sig_info "$V1"; sig_info "$V2"

say "v1 (identifier DR) creates the items"
run_probe "$V1" kci-1-write-v1 20 "" --mode keychain-write
say "v2 (identifier DR, different CDHash) reads, non-interactive"
run_probe "$V2" kci-2-read-v2-silent 20 "" --mode keychain-read --variant legacy --interactive no
logs_since "$LAST_LAUNCH_TS" kci-2-read-v2-silent
if [[ $KC_INTERACTIVE == 1 ]] && [[ $(jq -r '[.steps[] | select(.step == "legacy-data-noninteractive")][0].status' "$EVIDENCE/kci-2-read-v2-silent.json") != 0 ]]; then
  say "v2 needs a prompt; trying interactively with a 25s timeout"
  run_probe "$V2" kci-3-read-v2-interactive 25 "" --mode keychain-read --variant legacy --interactive yes
  logs_since "$LAST_LAUNCH_TS" kci-3-read-v2-interactive
fi

say "cleanup: v1 deletes the items"
run_probe "$V1" kci-4-delete-v1 20 "" --mode keychain-delete
security find-generic-password -s "$SERVICE" >/dev/null 2>&1 \
  && print "WARNING: an item for $SERVICE is still in the login keychain" \
  || print "no item for $SERVICE left in the login keychain"
kill_probes
