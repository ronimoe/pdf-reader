#!/bin/zsh
# Experiment 5: Gatekeeper and a downloaded, ad-hoc signed, sandboxed app.
#
#  1. Package probe v1 into a DMG with hdiutil; set com.apple.quarantine on it
#     the way a browser does.
#  2. Mount it, copy the app out with ditto, record xattrs, spctl and syspolicy_check.
#  3. Route 0 (baseline): launch the quarantined copy. Expect a block.
#  4. Route b: xattr -dr com.apple.quarantine, launch again.
#  5. Route c: a Homebrew cask in a local tap, file:// URL, --appdir in a test
#     folder: plain cask, then a cask whose postflight strips quarantine.
#  6. Route d (build from source) is what experiments 1-3 already do: a local
#     build carries no quarantine attribute and launches.
# Route a (System Settings > Privacy & Security > Open Anyway) is documented, not clicked.
#
# Launching a quarantined copy puts Gatekeeper's "Not Opened" alert on the user's
# screen. Those launches (route 0, the blocked-first half of 4b, the plain cask) only
# run with GK_LAUNCH_QUARANTINED=1. By default the script uses non-GUI checks
# (xattr, spctl, syspolicy_check) for quarantined copies and launches only
# unquarantined ones. The recorded run in results/05-gatekeeper.txt had it set.
# Never touches Gatekeeper settings (no spctl --master-disable, no --add).
source "${0:A:h}/lib.sh"
LAUNCH_QUARANTINED=${GK_LAUNCH_QUARANTINED:-0}
# spctl and syspolicy_check exit non-zero on a rejection, which is a result here.
set +o pipefail
kill_probes
V1=$BUILD_ROOT/v1/PlatformProbe.app
[[ -d $V1 ]] || build_probe v1 >/dev/null
GK="$FIXTURES/gatekeeper"
DMG="$BUILD_ROOT/PlatformProbe.dmg"
MNT="$BUILD_ROOT/mnt"
TAP=ronimoe/lectern-probe
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTOREMOVE=1

assess() { # assess <app>
  print "xattr: $(xattr "$1" | tr '\n' ' ')"
  print "quarantine: $(xattr -p com.apple.quarantine "$1" 2>/dev/null || print none)"
  print "spctl --assess -vv:"; spctl --assess -vv "$1" 2>&1 | sed 's/^/  /'
  print "syspolicy_check distribution:"; syspolicy_check distribution "$1" 2>&1 | sed 's/^/  /' | head -20
}

# Dismiss a Gatekeeper "Not Opened" alert left by a blocked launch. CoreServicesUIAgent
# shows it, ignores SIGTERM, and launchd restarts it on demand; nothing is approved
# this way (syspolicyd logs the prompt as unanswered). While the alert is pending,
# syspolicyd holds later launches of the same app, so this must run before the next route.
dismiss_gatekeeper_alert() {
  local pid
  pid=$(dialog_windows | sed -nE 's/.*owner=CoreServicesUIAgent pid=([0-9]+).*/\1/p' | head -1)
  if [[ -n $pid ]]; then
    print "Gatekeeper alert on screen (CoreServicesUIAgent pid $pid); dismissing it by restarting the agent"
    kill -9 "$pid" 2>/dev/null || true
    sleep 2
    print "now: $(dialog_windows)"
  fi
  kill_probes
}

say "1. build the DMG"
rm -rf "$GK" "$BUILD_ROOT/dmg-staging" "$DMG"; mkdir -p "$GK" "$BUILD_ROOT/dmg-staging"
ditto "$V1" "$BUILD_ROOT/dmg-staging/PlatformProbe.app"
ln -s /Applications "$BUILD_ROOT/dmg-staging/Applications"
hdiutil create -quiet -volname PlatformProbe -srcfolder "$BUILD_ROOT/dmg-staging" -fs APFS -format UDZO "$DMG"
Q="0083;$(printf '%x' $(date +%s));Safari;$(uuidgen)"
xattr -w com.apple.quarantine "$Q" "$DMG"
print "DMG quarantine: $(xattr -p com.apple.quarantine "$DMG")"
print "spctl on the DMG (open, primary signature):"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'

say "2. mount, copy the app out"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG"
print "inside the mounted image: $(xattr -p com.apple.quarantine "$MNT/PlatformProbe.app" 2>/dev/null || print 'no quarantine')"
ditto "$MNT/PlatformProbe.app" "$GK/PlatformProbe.app"
ditto "$MNT/PlatformProbe.app" "$GK/fresh/PlatformProbe.app"   # never launched, for route b
ditto "$MNT/PlatformProbe.app" "$GK/blocked/PlatformProbe.app" # blocked first, then route b
hdiutil detach -quiet "$MNT"
APP="$GK/PlatformProbe.app"
assess "$APP"

say "3. route 0: launch the quarantined copy (expect a block)"
if [[ $LAUNCH_QUARANTINED == 1 ]]; then
run_probe "$APP" gk-0-quarantined 15 "" --mode info
logs_since "$LAST_LAUNCH_TS" gk-0-quarantined
/usr/bin/log show --start "$LAST_LAUNCH_TS" --style compact --predicate 'process == "syspolicyd"' 2>/dev/null \
  | grep -iE 'PlatformProbe|GK |gatekeeper|evaluat|prompt|block|reject|not notarized|unsigned|adhoc' | cut -c1-300 | tail -25 \
  > "$EVIDENCE/logs-gk-0-syspolicyd.txt" || true
print "(syspolicyd excerpt: results/logs-gk-0-syspolicyd.txt)"
dismiss_gatekeeper_alert
[[ -d $APP ]] && print "quarantined copy still in place" \
  || print "quarantined copy is gone: someone chose Move to Trash in the Gatekeeper alert"
else
  print "skipped (would show the Gatekeeper alert); set GK_LAUNCH_QUARANTINED=1 to launch it"
fi

say "4a. route b on a fresh copy: xattr -dr com.apple.quarantine, then launch"
FRESH="$GK/fresh/PlatformProbe.app"
print "before: $(xattr -p com.apple.quarantine "$FRESH" 2>/dev/null || print none)"
xattr -dr com.apple.quarantine "$FRESH"
assess "$FRESH"
run_probe "$FRESH" gk-b-xattr-removed 20 "" --mode info
dismiss_gatekeeper_alert

say "4b. route b after a blocked launch (the user tried to open it first)"
BLOCKED="$GK/blocked/PlatformProbe.app"
if [[ $LAUNCH_QUARANTINED == 1 ]]; then
  run_probe "$BLOCKED" gk-b-blocked-first 8 "" --mode info
  dismiss_gatekeeper_alert
else
  print "blocked-first launch skipped (GK_LAUNCH_QUARANTINED=0); this is then the same as 4a"
fi
if [[ -d $BLOCKED ]]; then
  xattr -dr com.apple.quarantine "$BLOCKED"
  print "quarantine now: $(xattr -p com.apple.quarantine "$BLOCKED" 2>/dev/null || print none)"
  run_probe "$BLOCKED" gk-b-after-block 20 "" --mode info
  dismiss_gatekeeper_alert
else
  print "blocked copy is gone (Move to Trash chosen in the alert); 4b skipped"
fi

say "5. route c: Homebrew cask from a local tap"
brew --version | head -1
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
brew untap "$TAP" >/dev/null 2>&1 || true
brew tap-new --no-git "$TAP" >/dev/null
TAPDIR="$(brew --repository)/Library/Taps/ronimoe/homebrew-lectern-probe"
mkdir -p "$TAPDIR/Casks"
write_cask() { # write_cask <name> <postflight: yes|no>
  {
    print "cask \"$1\" do"
    print "  version \"0.1.0\""
    print "  sha256 \"$SHA\""
    print "  url \"file://$DMG\""
    print "  name \"PlatformProbe\""
    print "  desc \"Lectern M0c platform probe (test only)\""
    print "  homepage \"https://github.com/ronimoe/pdf-reader\""
    print "  app \"PlatformProbe.app\""
    if [[ $2 == yes ]]; then
      # Legacy Ruby flight block: deprecated, third-party taps only.
      print "  postflight do"
      print "    system_command \"/usr/bin/xattr\", args: [\"-dr\", \"com.apple.quarantine\", \"#{appdir}/PlatformProbe.app\"]"
      print "  end"
    elif [[ $2 == steps ]]; then
      # Structured steps (brew 7); runs in Homebrew's install-step sandbox.
      print "  postflight_steps do"
      print "    run \"/usr/bin/xattr\", args: [\"-dr\", \"com.apple.quarantine\", \"{{appdir}}/PlatformProbe.app\"]"
      print "  end"
    fi
    print "end"
  } > "$TAPDIR/Casks/$1.rb"
}
write_cask platform-probe no
write_cask platform-probe-unquarantined yes
write_cask platform-probe-steps steps

for cask in platform-probe platform-probe-unquarantined platform-probe-steps; do
  APPDIR="$FIXTURES/brew-$cask"
  rm -rf "$APPDIR"; mkdir -p "$APPDIR"
  say "5.$cask: brew install --cask --appdir=$APPDIR"
  # (The filter drops brew's tap-trust warning about the user's other, unrelated taps.)
  brew install --cask --appdir="$APPDIR" "$TAP/$cask" 2>&1 \
    | grep -vE '^==> (Downloading|Fetching)|not trusted|^    [a-z]+/[a-z-]+$|^Homebrew is currently|^from these taps|^Prefer trusting|^Trust |brew trust|^Whole-tap|^casks and commands|^Untap them|brew untap|^For more information|Tap-Trust|^ *$' \
    | sed 's/^/  /'
  assess "$APPDIR/PlatformProbe.app"
  if [[ $LAUNCH_QUARANTINED == 1 ]] || ! xattr -p com.apple.quarantine "$APPDIR/PlatformProbe.app" >/dev/null 2>&1; then
    run_probe "$APPDIR/PlatformProbe.app" "gk-c-$cask" 15 "" --mode info
    logs_since "$LAST_LAUNCH_TS" "gk-c-$cask"
    dismiss_gatekeeper_alert
  else
    print "installed copy is quarantined; launch skipped (would show the Gatekeeper alert)"
  fi
  brew uninstall --cask "$TAP/$cask" 2>&1 | grep -vE 'postflight|Please report|homebrew-lectern-probe|^ *$' | sed 's/^/  /'
done
brew untap "$TAP" 2>&1 | sed 's/^/  /'

say "6. route d: a local build (no quarantine)"
assess "$V1"
run_probe "$V1" gk-d-local-build 20 "" --mode info
kill_probes
