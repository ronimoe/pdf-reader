#!/bin/zsh
# Experiment 3c (attribution control): is the Keychain prompt caused by the sandbox?
# Same as experiment 3 but v1 and v2 are built WITHOUT the App Sandbox (empty
# entitlements, still ad-hoc + hardened runtime). Non-interactive reads only, so
# no prompt can appear. Unsandboxed, results go to the real ~/Library/Application Support.
source "${0:A:h}/lib.sh"
kill_probes
RESULTS="$HOME/Library/Application Support/PlatformProbe/results"
ENT="$BUILD_ROOT/no-sandbox.entitlements"
plutil -create xml1 "$ENT"
for tag in v1-nosandbox v2-nosandbox; do
  build_probe "$tag" PlatformProbe CODE_SIGN_ENTITLEMENTS="$ENT" >/dev/null
done
V1=$BUILD_ROOT/v1-nosandbox/PlatformProbe.app
V2=$BUILD_ROOT/v2-nosandbox/PlatformProbe.app
sig_info "$V1"; sig_info "$V2"
run_probe "$V1" kcn-1-write-v1 20 "" --mode keychain-write
run_probe "$V1" kcn-2-read-v1 20 "" --mode keychain-read --variant legacy --interactive no
run_probe "$V2" kcn-3-read-v2-silent 20 "" --mode keychain-read --variant legacy --interactive no
logs_since "$LAST_LAUNCH_TS" kcn-3-read-v2-silent
run_probe "$V1" kcn-4-delete-v1 20 "" --mode keychain-delete
security find-generic-password -s io.github.ronimoe.PlatformProbe.m0c-test >/dev/null 2>&1 \
  && print "WARNING: test item still present" || print "no test item left"
rm -rf "$HOME/Library/Application Support/PlatformProbe"
kill_probes
