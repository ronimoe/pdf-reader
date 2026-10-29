#!/bin/zsh
# Experiment 3: can a generic-password item created by v1 be read by v2 without a prompt?
#
# Two variants per run: the legacy file-based login keychain (what a sandboxed app
# without keychain-access-groups uses) and the data protection keychain.
# Each read first asks for the secret with UI forbidden (a needed prompt shows up
# as errSecInteractionNotAllowed), then, with --interactive yes, asks normally.
# A prompt nobody answers is detected by the timeout, reported, and the probe killed.
# v1 deletes the items at the end (it is on their ACL); the script then verifies
# from the shell (attributes only, which never prompts) that nothing is left.
source "${0:A:h}/lib.sh"
# Interactive reads by v2 put a SecurityAgent prompt on screen; they only run with
# KC_INTERACTIVE=1 (the recorded runs in results/ had it set).
KC_INTERACTIVE=${KC_INTERACTIVE:-0}
kill_probes
V1=$BUILD_ROOT/v1/PlatformProbe.app
V2=$BUILD_ROOT/v2/PlatformProbe.app
[[ -d $V1 ]] || build_probe v1 >/dev/null
[[ -d $V2 ]] || build_probe v2 >/dev/null
SERVICE=io.github.ronimoe.PlatformProbe.m0c-test

say "v1 creates the items"
run_probe "$V1" kc-1-write-v1 20 "" --mode keychain-write
say "item in the login keychain (attributes only)"
security find-generic-password -s "$SERVICE" -a legacy 2>&1 | grep -E 'keychain:|class|"acct"|"svce"|"labl"' || print "(legacy item not found)"

say "v1 reads (control: same signature)"
run_probe "$V1" kc-2-read-v1 20 "" --mode keychain-read --interactive yes

say "v2 (different CDHash) reads, non-interactive only"
run_probe "$V2" kc-3-read-v2-silent 20 "" --mode keychain-read --interactive no
logs_since "$LAST_LAUNCH_TS" kc-3-read-v2-silent

if [[ $KC_INTERACTIVE == 1 ]]; then
say "v2 reads the legacy item interactively; a prompt will time out after 25s"
run_probe "$V2" kc-4-read-v2-legacy-interactive 25 "" --mode keychain-read --variant legacy --interactive yes
logs_since "$LAST_LAUNCH_TS" kc-4-read-v2-legacy-interactive
sleep 2
print "after kill: $(dialog_windows | tr '\n' ';')"
else
  say "interactive v2 read skipped (KC_INTERACTIVE=0): it would show a SecurityAgent prompt"
fi

say "v2 reads the data protection item interactively"
run_probe "$V2" kc-5-read-v2-dp-interactive 25 "" --mode keychain-read --variant dataProtection --interactive yes

say "cleanup: v1 deletes the items"
run_probe "$V1" kc-6-delete-v1 20 "" --mode keychain-delete
if security find-generic-password -s "$SERVICE" >/dev/null 2>&1; then
  print "WARNING: an item for $SERVICE is still in the login keychain"
else
  print "no item for $SERVICE left in the login keychain"
fi
kill_probes
