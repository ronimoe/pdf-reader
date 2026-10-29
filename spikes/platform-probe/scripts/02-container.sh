#!/bin/zsh
# Experiment 2: can a rebuilt, re-signed probe read what the previous build wrote
# to its sandbox container, and does macOS show a dialog when it opens it?
#
# Starts from an empty container (Data/ removed). v1 creates it and writes a marker file plus a
# UserDefaults value; v1 reads them back (control); v2 (new CDHash) reads them
# and writes a new file. The container metadata and the system log around the v2
# launch are captured. After each run lib.sh lists on-screen dialog windows.
source "${0:A:h}/lib.sh"
kill_probes
V1=$BUILD_ROOT/v1/PlatformProbe.app
V2=$BUILD_ROOT/v2/PlatformProbe.app
[[ -d $V1 ]] || build_probe v1 >/dev/null
[[ -d $V2 ]] || build_probe v2 >/dev/null

say "empty the probe container"
# The container root and its .com.apple.containermanagerd.metadata.plist are
# protected (rm gets EPERM even for the owning user); Data/ can be removed.
rm -rf "$CONTAINER/Data" && print "removed $CONTAINER/Data"
rm -rf "$CONTAINER" 2>&1 | sed 's/^/  /' || true
mkdir -p "$EVIDENCE"

say "v1 creates the container and writes"
run_probe "$V1" ct-1-write-v1 20 "" --mode container-write
say "container metadata after v1 created it"
container_metadata | tee "$EVIDENCE/container-metadata-after-v1.txt"

say "v1 reads (control)"
run_probe "$V1" ct-2-read-v1 20 "" --mode container-read

say "v2 (different CDHash) reads"
run_probe "$V2" ct-3-read-v2 30 "" --mode container-read
logs_since "$LAST_LAUNCH_TS" ct-3-read-v2
say "container metadata after v2 opened it"
container_metadata | tee "$EVIDENCE/container-metadata-after-v2.txt"
diff "$EVIDENCE/container-metadata-after-v1.txt" "$EVIDENCE/container-metadata-after-v2.txt" \
  && print "metadata unchanged" || print "metadata changed (diff above)"

say "v2 writes, v1 reads it back (downgrade direction)"
run_probe "$V2" ct-4-write-v2 20 "" --mode container-write
run_probe "$V1" ct-5-read-v1 20 "" --mode container-read
kill_probes
