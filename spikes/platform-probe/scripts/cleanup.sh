#!/bin/zsh
# Undo everything the experiments leave on this Mac. Safe to run repeatedly.
# Never shows a dialog: the Keychain items are deleted by the build that created
# them (v1 is on their ACL), never through `security delete-*`, which would prompt.
source "${0:A:h}/lib.sh"
set +o pipefail
SERVICE=io.github.ronimoe.PlatformProbe.m0c-test

say "kill probe processes and the appcast server"
kill_probes
lsof -ti tcp:8765 2>/dev/null | xargs kill 2>/dev/null || true

say "Keychain test items"
if security find-generic-password -s "$SERVICE" >/dev/null 2>&1; then
  for v in v1 v1-iddr; do
    [[ -d $BUILD_ROOT/$v/PlatformProbe.app ]] && run_probe "$BUILD_ROOT/$v/PlatformProbe.app" "cleanup-keychain-$v" 15 "" --mode keychain-delete >/dev/null
  done
fi
security find-generic-password -s "$SERVICE" >/dev/null 2>&1 \
  && print "WARNING: an item for $SERVICE is still in the login keychain (delete it in Keychain Access)" \
  || print "no $SERVICE items left"

say "Sparkle throwaway EdDSA key (account lectern-m0c-probe)"
# The item belongs to Sparkle's ad-hoc signed generate_keys, so deleting it from
# here would prompt. Report it instead; it signs nothing outside this spike.
if security find-generic-password -a lectern-m0c-probe >/dev/null 2>&1; then
  print "still present: generic password, account lectern-m0c-probe (service https://sparkle-project.org)."
  print "Delete it in Keychain Access (search 'lectern-m0c-probe') if you want it gone."
else
  print "not present"
fi
rm -f "$BUILD_ROOT/sparkle-private-key.txt"

say "unmount DMGs"
for m in $(hdiutil info | awk '/PlatformProbe/ && /\/dev\/disk/ {print $1}'); do hdiutil detach -quiet "$m" || true; done
[[ -d $BUILD_ROOT/mnt ]] && { hdiutil detach -quiet "$BUILD_ROOT/mnt" 2>/dev/null || true; }

say "Homebrew test tap"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1
for c in platform-probe platform-probe-unquarantined platform-probe-steps; do
  brew list --cask "ronimoe/lectern-probe/$c" >/dev/null 2>&1 && brew uninstall --cask "ronimoe/lectern-probe/$c" >/dev/null 2>&1
done
brew untap ronimoe/lectern-probe >/dev/null 2>&1 || true
brew tap | grep -q lectern-probe && print "WARNING: tap still present" || print "tap removed"

say "installed test apps and fixtures"
rm -rf /Applications/PlatformProbeSparkle.app "$FIXTURES"
print "removed /Applications/PlatformProbeSparkle.app and $FIXTURES"

say "unregister probe copies from LaunchServices"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in $BUILD_ROOT/*/PlatformProbe*.app(N) $BUILD_ROOT/DerivedData-*/Build/Products/*/PlatformProbe*.app(N); do
  "$LSREG" -u "$app" 2>/dev/null || true
done

say "probe containers"
# The container root and its metadata plist are protected (EPERM even for the
# owner); only Data/ can be removed from a shell.
for id in io.github.ronimoe.PlatformProbe io.github.ronimoe.PlatformProbeSparkle; do
  c="$HOME/Library/Containers/$id"
  [[ -d $c ]] || continue
  rm -rf "$c/Data" 2>/dev/null || true
  rm -rf "$c" 2>/dev/null || print "$c: Data/ removed; the protected root stays (remove it in Finder if wanted)"
done
print "done"
