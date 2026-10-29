#!/bin/zsh
# Experiment 4: Sparkle 2 updating an ad-hoc signed, sandboxed app, end to end.
#
#  1. Throwaway EdDSA key (login Keychain, unique account; deleted by cleanup.sh).
#  2. Build PlatformProbeSparkle v1 (CFBundleVersion 1) and v2 (2, code change).
#  3. "Install" v1 by copying it to $FIXTURES/Applications.
#  4. Zip v2, sign it with sign_update, write appcast.xml, serve both from
#     python3 -m http.server on 127.0.0.1.
#  5. Launch the installed v1 with --mode sparkle-update (headless driver that
#     always answers "install"), wait for the relaunch.
#  6. Check on disk which build is installed (CFBundleVersion, CDHash, quarantine).
source "${0:A:h}/lib.sh"
kill_probes
SP_ID=io.github.ronimoe.PlatformProbeSparkle
RESULTS="$HOME/Library/Containers/$SP_ID/Data/Library/Application Support/PlatformProbe/results"
KEY_ACCOUNT=lectern-m0c-probe
PORT=8765
SERVE="$BUILD_ROOT/sparkle-serve"
# Override with SPARKLE_INSTALL_DIR=/Applications to test App Management protection there.
INSTALL_DIR="${SPARKLE_INSTALL_DIR:-$FIXTURES/Applications}"
BIN=$(print -r -- $BUILD_ROOT/DerivedData-*/SourcePackages/artifacts/sparkle/Sparkle/bin(N[1]))
if [[ -z $BIN ]]; then (cd "$PROBE_DIR" && xcodegen generate --quiet) && \
  xcodebuild -resolvePackageDependencies -project "$PROBE_DIR/PlatformProbe.xcodeproj" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/DerivedData-PlatformProbeSparkle-v1/SourcePackages" >/dev/null
  BIN="$BUILD_ROOT/DerivedData-PlatformProbeSparkle-v1/SourcePackages/artifacts/sparkle/Sparkle/bin"
fi

say "throwaway EdDSA key (account $KEY_ACCOUNT)"
"$BIN/generate_keys" --account "$KEY_ACCOUNT" >/dev/null 2>&1 || true
PUBKEY=$("$BIN/generate_keys" --account "$KEY_ACCOUNT" -p)
print "public key: $PUBKEY"
# sign_update is a different ad-hoc signed binary, so reading the key from the
# Keychain makes it prompt (cdhash partition; see experiment 3). Export the key
# once with generate_keys (the item's creator, no prompt) and sign from the file.
KEYFILE="$BUILD_ROOT/sparkle-private-key.txt"
[[ -s $KEYFILE ]] || "$BIN/generate_keys" --account "$KEY_ACCOUNT" -x "$KEYFILE" >/dev/null
chmod 600 "$KEYFILE"

say "build v1 and v2"
for tag in v1 v2; do
  build_probe "$tag" PlatformProbeSparkle SPARKLE_PUBLIC_ED_KEY="$PUBKEY" \
    SPARKLE_FEED_URL="http://127.0.0.1:$PORT/appcast.xml" >/dev/null
done
V1=$BUILD_ROOT/v1/PlatformProbeSparkle.app
V2=$BUILD_ROOT/v2/PlatformProbeSparkle.app
sig_info "$V1"; sig_info "$V2"
say "signatures of Sparkle's embedded helpers in v1"
for p in Contents/Frameworks/Sparkle.framework \
         Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc \
         Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
         Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app; do
  print -n "$p: "; codesign -dvv "$V1/$p" 2>&1 | grep -E '^(Signature|TeamIdentifier|CodeDirectory)' | tr '\n' ' '; print
done

say "install v1"
mkdir -p "$INSTALL_DIR"; rm -rf "$INSTALL_DIR/PlatformProbeSparkle.app"
ditto "$V1" "$INSTALL_DIR/PlatformProbeSparkle.app"
INSTALLED="$INSTALL_DIR/PlatformProbeSparkle.app"

say "archive, sign and publish v2"
rm -rf "$SERVE"; mkdir -p "$SERVE"
ditto -c -k --keepParent "$V2" "$SERVE/PlatformProbeSparkle-2.zip"
SIG=$(gtimeout 30 "$BIN/sign_update" --ed-key-file "$KEYFILE" "$SERVE/PlatformProbeSparkle-2.zip")
print "sign_update: $SIG"
cat > "$SERVE/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PlatformProbeSparkle</title>
    <item>
      <title>Version 2</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>0.1.0 (2)</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="http://127.0.0.1:$PORT/PlatformProbeSparkle-2.zip" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
lsof -ti tcp:$PORT | xargs kill 2>/dev/null || true
python3 -I -m http.server $PORT --bind 127.0.0.1 --directory "$SERVE" >"$BUILD_ROOT/http.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1
curl -fsS "http://127.0.0.1:$PORT/appcast.xml" | head -3

say "installed v1 before update: CFBundleVersion $(defaults read "$INSTALLED/Contents/Info" CFBundleVersion)"
if [[ -d $RESULTS ]]; then find "$RESULTS" -name "*.json" -delete; fi
run_probe "$INSTALLED" sp-1-update-v1 90 "" --mode sparkle-update
logs_since "$LAST_LAUNCH_TS" sp-1-update-v1

say "waiting up to 60s for the relaunched app to record itself"
relaunch=""
for _ in {1..120}; do
  relaunch=$(print -r -- "$RESULTS"/launch-*.json(N[1]))
  [[ -n $relaunch ]] && break
  sleep 0.5
done
if [[ -n $relaunch ]]; then
  jq '{runID, buildTag, codeVariant, bundleVersion, bundlePath, sandboxed}' "$relaunch"
  cp "$relaunch" "$EVIDENCE/sp-2-relaunched.json"
else
  print "no relaunch recorded"
fi

say "on disk after update"
print "CFBundleVersion: $(defaults read "$INSTALLED/Contents/Info" CFBundleVersion)"
codesign -dvvv "$INSTALLED" 2>&1 | grep -E '^CDHash='
print "v2 build CDHash: $(codesign -dvvv "$V2" 2>&1 | grep -E '^CDHash=')"
print "xattrs: $(xattr "$INSTALLED" | tr '\n' ' ')"
codesign --verify --strict "$INSTALLED" && print "installed app signature valid"
print "http requests served:"; grep -E 'GET' "$BUILD_ROOT/http.log" | sed 's/^/  /'
kill_probes
