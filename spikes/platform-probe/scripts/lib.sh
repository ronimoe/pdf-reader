#!/bin/zsh
# Shared helpers for the M0c platform probe scripts. Source it; don't run it.
set -euo pipefail

PROBE_DIR=${0:A:h:h}
BUILD_ROOT="$PROBE_DIR/build"
EVIDENCE="$PROBE_DIR/results"
BUNDLE_ID=io.github.ronimoe.PlatformProbe
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID"
RESULTS="$CONTAINER/Data/Library/Application Support/PlatformProbe/results"
# Outside the container and outside Desktop/Documents/Downloads (no TCC prompt),
# so the sandbox denies it unless a sandbox extension says otherwise.
FIXTURES="${PROBE_FIXTURES:-$HOME/PlatformProbeFixtures}"
mkdir -p "$BUILD_ROOT" "$EVIDENCE"

say() { print -r -- "== $*"; }

# build_probe <tag> [target] [extra xcodebuild settings...]
# Tags starting with v1 are the base build; any other tag also compiles with PROBE_V2 (a code change)
# and CFBundleVersion 2, so the CDHash and designated requirement change.
build_probe() {
  local tag=$1 target=${2:-PlatformProbe}
  shift; (( $# )) && shift
  local -a extra
  if [[ $tag != v1* ]]; then
    extra=(CURRENT_PROJECT_VERSION=2 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PROBE_V2')
  fi
  (cd "$PROBE_DIR" && xcodegen generate --quiet)
  local dd="$BUILD_ROOT/DerivedData-$target-$tag"
  xcodebuild -project "$PROBE_DIR/PlatformProbe.xcodeproj" -scheme "$target" -configuration Release \
    -derivedDataPath "$dd" -destination 'platform=macOS' \
    PROBE_BUILD_TAG="$tag" "${extra[@]}" "$@" build >"$BUILD_ROOT/build-$target-$tag.log" 2>&1 \
    || { tail -40 "$BUILD_ROOT/build-$target-$tag.log"; return 1; }
  rm -rf "$BUILD_ROOT/$tag/$target.app"
  mkdir -p "$BUILD_ROOT/$tag"
  ditto "$dd/Build/Products/Release/$target.app" "$BUILD_ROOT/$tag/$target.app"
  print -r -- "$BUILD_ROOT/$tag/$target.app"
}

# sig_info <app>: the signature facts that decide what macOS ties to the app.
sig_info() {
  local app=$1
  print -r -- "-- $app"
  codesign -dvvv "$app" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|CDHash=|Signature|TeamIdentifier|Runtime Version|Info.plist)' || true
  print -n -- "Designated requirement: "; codesign -d -r- "$app" 2>&1 | grep designated || true
  codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true; print
  codesign --verify --strict --verbose=1 "$app" 2>&1 | tail -1
}

kill_probes() {
  pkill -f "/PlatformProbe(Sparkle)?.app/Contents/MacOS/" 2>/dev/null || true
  sleep 0.5
}

# dialog_windows: on-screen windows owned by SecurityAgent, UserNotificationCenter,
# CoreServicesUIAgent or the probe (those processes always run; only a window means a dialog).
dialog_windows() {
  local tool="$BUILD_ROOT/onscreen-windows"
  [[ -x $tool ]] || swiftc -O -o "$tool" "$PROBE_DIR/scripts/onscreen-windows.swift"
  "$tool"
}

# run_probe <app> <run-id> <timeout-seconds> <file-or-empty> [probe args...]
# Launches through LaunchServices (`open`), waits for a complete result JSON,
# and on timeout reports likely dialog owners and kills the probe.
# Sets RUN_TIMED_OUT=1 on timeout.
RUN_TIMED_OUT=0
run_probe() {
  local app=$1 run_id=$2 timeout=$3 file=$4
  shift 4
  local out="$RESULTS/$run_id.json"
  rm -f "$out"
  RUN_TIMED_OUT=0
  local agents_before; agents_before=$( { pgrep -x SecurityAgent || true; } | tr '\n' ' ')
  LAST_LAUNCH_TS=$(date '+%Y-%m-%d %H:%M:%S')
  say "launch $run_id: $(basename ${app:h}) $(basename $app) ${file:+file=$file} $*"
  if [[ -n $file ]]; then
    open -n -a "$app" "$file" --args --run-id "$run_id" "$@" || print "open exited $?"
  else
    open -n -a "$app" --args --run-id "$run_id" "$@" || print "open exited $?"
  fi
  local waited=0
  while (( waited < timeout * 10 )); do
    if [[ -f $out ]] && [[ $(jq -r .complete "$out" 2>/dev/null) == true ]]; then break; fi
    sleep 0.1; (( waited += 1 ))
  done
  if ! { [[ -f $out ]] && [[ $(jq -r .complete "$out" 2>/dev/null) == true ]]; }; then
    RUN_TIMED_OUT=1
    print "TIMEOUT after ${timeout}s: no complete result for $run_id"
    print "on-screen dialog windows: $(dialog_windows | tr '\n' ';')"
    print "probe processes: $(pgrep -fl 'PlatformProbe' | tr '\n' ' ')"
    kill_probes
    # A Keychain prompt outlives its killed client. Dismiss only SecurityAgent
    # instances that appeared after this launch (never one the user already had).
    sleep 1
    local pid
    for pid in $(pgrep -x SecurityAgent || true); do
      if [[ " $agents_before " != *" $pid "* ]]; then
        print "killing orphaned SecurityAgent $pid spawned by this run (it ignores SIGTERM)"; kill -9 "$pid" 2>/dev/null || true
      fi
    done
  fi
  sleep 0.5
  print "after run: $(dialog_windows | tr '\n' ';')"
  if [[ -f $out ]]; then
    jq '{runID, mode, buildTag, codeVariant, bundleVersion, sandboxed, complete, steps: [.steps[] | del(.at)]}' "$out"
    cp "$out" "$EVIDENCE/$run_id.json" 2>/dev/null || true
  else
    print "no result file at $out"
  fi
}

# logs_since <timestamp> <name>: what the system daemons that could block or prompt
# said since <timestamp>: containermanagerd, TCC services requested, SecurityAgent,
# Keychain daemons, syspolicyd (Gatekeeper) and sandbox denials for the probe.
logs_since() {
  local since=$1 name=$2
  local f="$EVIDENCE/logs-$name.txt"
  {
    print "# containermanagerd (lines naming the probe, writes, errors)"
    /usr/bin/log show --start "$since" --style compact --info --debug --predicate 'process == "containermanagerd"' 2>/dev/null \
      | grep -E 'PlatformProbe|[Ee]rror =|denied|code ?sign|identity' | grep -v 'error = (null)' | cut -c1-300 | tail -20
    print "# TCC services requested (all processes)"
    /usr/bin/log show --start "$since" --style compact --info --predicate 'process == "tccd"' 2>/dev/null \
      | grep -oE 'service="?kTCC[A-Za-z]+' | tr -d '"' | sort | uniq -c
    print "# TCC lines naming the probe"
    /usr/bin/log show --start "$since" --style compact --info --predicate 'process == "tccd"' 2>/dev/null \
      | grep -E 'PlatformProbe' | cut -c1-300 | tail -10
    print "# SecurityAgent / securityd / secd / syspolicyd lines naming the probe, and SecurityAgent activity"
    /usr/bin/log show --start "$since" --style compact --info --predicate 'process == "SecurityAgent" OR process == "securityd" OR process == "secd" OR process == "syspolicyd"' 2>/dev/null \
      | grep -E 'PlatformProbe|SecurityAgent\[' | cut -c1-300 | tail -25
    print "# sandbox denials for the probe"
    /usr/bin/log show --start "$since" --style compact --predicate 'process == "kernel" AND eventMessage CONTAINS "PlatformProbe" AND eventMessage CONTAINS "deny"' 2>/dev/null \
      | grep -v '^Timestamp' | cut -c1-300 | tail -20
  } > "$f" 2>&1 || true
  print "(system log excerpt: results/logs-$name.txt)"
}

container_metadata() {
  local f="$CONTAINER/.com.apple.containermanagerd.metadata.plist"
  ls -lO@ "$CONTAINER" 2>&1 || true
  plutil -p "$f" 2>&1 | grep -vE 'Data =|bytes' | head -40 || true
}

make_pdf() { # make_pdf <path>
  mkdir -p "${1:h}"
  python3 -I - "$1" <<'PY'
import sys
objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>"]
out = bytearray(b"%PDF-1.7\n")
offs = []
for i, o in enumerate(objs, 1):
    offs.append(len(out))
    out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for off in offs:
    out += b"%010d 00000 n \n" % off
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(sys.argv[1], "wb").write(out)
PY
  qpdf --check "$1" >/dev/null
}
