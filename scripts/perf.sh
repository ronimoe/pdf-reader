#!/bin/zsh
# Runs the performance tests on the representative documents (spec §9.1, docs/performance.md):
# AppTests/M6/RepresentativePerformanceTests.swift, headlessly, and nothing else.
#
# The test host is sandboxed and can't read the repository, so the four files are copied into its
# container's temporary folder with an `enabled` marker beside them; without the marker (as in
# scripts/test.sh) the suite is skipped. Every measurement is a `PERF|name|value|unit|threshold|max-or-min`
# line in results.txt there, copied to build/perf/results.txt. The run fails if any test fails
# (a value over its threshold fails its test) or if fewer measurements came back than expected,
# so a suite that silently didn't run can't pass.
#
# The build is the test configuration (Debug, so the tests can use @testable) compiled with the
# Release optimisation level (-O, whole module) into its own build/DerivedData-perf, so the app's and
# LecternKit's own code runs at shipping speed. PDFKit and CoreGraphics are system code either way.
#
# Needs scripts/corpus/bootstrap to have fetched Tests/Corpus/public/fetched/. Takes a few minutes.
# Usage: scripts/perf.sh [suite/test]  e.g. scripts/perf.sh RepresentativePerformanceTests/search (skips the count check)
set -uo pipefail
cd "${0:A:h:h}"
mkdir -p build/logs build/perf

EXPECTED=37   # 4 opens, 4 × 2 scrolling, 4 × 2 drawing, 10 search (3 per common word, 2 per rare one), 4 thumbnail runs, 3 annotation list and save
ONLY=${1:-}
DERIVED=build/DerivedData-perf
OPTIMISED=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s)
files=(
  Tests/Corpus/public/realworld/gpo-style-manual-2016.pdf
  Tests/Corpus/public/realworld/postgresql-17.11-US.pdf
  Tests/Corpus/public/realworld/annals-surgery-1886-anthrax-scan.pdf
  Tests/Corpus/public/fetched/nasa-earth-at-night.pdf
)
for f in $files; do
  [[ -f $f ]] || { echo "perf: $f is missing; run scripts/corpus/bootstrap"; exit 1; }
done

xcodegen generate --quiet || exit 1
container="$HOME/Library/Containers/io.github.ronimoe.Lectern"
if [[ ! -d $container/Data/tmp ]]; then
  # macOS creates the container the first time the sandboxed test host runs; don't make it by hand.
  echo "== creating the test host's container (one quick test)"
  xcodebuild -project Lectern.xcodeproj -scheme Lectern -destination 'platform=macOS' -derivedDataPath $DERIVED $OPTIMISED \
    test -only-testing:LecternTests/ReleaseTests > build/logs/perf-container.log 2>&1 || { echo "perf: setup test failed (build/logs/perf-container.log)"; exit 1; }
fi
staged="$container/Data/tmp/LecternPerfCorpus"
cleanup() { rm -rf "$staged"; }
trap cleanup EXIT
trap 'exit 130' INT
rm -rf "$staged" && mkdir -p "$staged"
for f in $files; do cp "$f" "$staged/"; done
touch "$staged/enabled"

target=LecternTests/${ONLY:-RepresentativePerformanceTests}
echo "== xcodebuild test, optimised: $target (log: build/logs/perf.log)"
xcodebuild -project Lectern.xcodeproj -scheme Lectern -destination 'platform=macOS' -derivedDataPath $DERIVED $OPTIMISED \
  test -only-testing:$target > build/logs/perf.log 2>&1
result=$?
grep -v "\[Connection\]" build/logs/perf.log | grep -E "error:|✘|Test run with|TEST SUCCEEDED|TEST FAILED" | cut -c1-240

if [[ -f "$staged/results.txt" ]]; then
  cp "$staged/results.txt" build/perf/results.txt
else
  : > build/perf/results.txt
fi
{
  echo "machine: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
  printf '%-62s %12s %-8s %s\n' measurement value unit threshold
  awk -F'|' '$1 == "PERF" { printf "%-62s %12.4f %-8s %s %s\n", $2, $3, $4, ($6 == "min" ? "≥" : "≤"), $5 }' build/perf/results.txt
} | tee build/perf/summary.txt
count=$(grep -c '^PERF|' build/perf/results.txt)
echo "== $count of $EXPECTED measurements"
if [[ -z $ONLY ]]; then
  (( count >= EXPECTED )) || { echo "perf: expected $EXPECTED measurements, got $count"; result=1; }
else
  (( count > 0 )) || { echo "perf: no measurements came back"; result=1; }
fi
if [[ $result -eq 0 ]]; then echo "PERF PASSED"; else echo "PERF FAILED (build/logs/perf.log)"; fi
exit $result
