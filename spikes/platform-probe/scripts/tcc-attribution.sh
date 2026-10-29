#!/bin/zsh
# Who does TCC credit the probe's and Sparkle's processes to, and were any App
# Management (kTCCServiceSystemPolicyAppBundles) requests about them?
# Usage: scripts/tcc-attribution.sh <start> <end>   (log timestamps)
set -uo pipefail
start=$1 end=$2
print "# tccd attribution for probe and Sparkle processes, $start to $end"
/usr/bin/log show --start "$start" --end "$end" --style compact --info --predicate 'process == "tccd"' 2>/dev/null \
  | grep 'AUTHREQ_ATTRIBUTION' | grep -E 'PlatformProbe|org.sparkle-project' \
  | grep -oE '(responsible|accessing|requesting)=\{TCCDProcess: identifier=[^,]+' | sort | uniq -c
print "# subjects of kTCCServiceSystemPolicyAppBundles requests in the same window"
/usr/bin/log show --start "$start" --end "$end" --style compact --info --predicate 'process == "tccd"' 2>/dev/null \
  | grep -A3 'service=kTCCServiceSystemPolicyAppBundles' | grep -oE 'subject=[^,]+' | sort | uniq -c
