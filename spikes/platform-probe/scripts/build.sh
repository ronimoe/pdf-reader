#!/bin/zsh
# Usage: scripts/build.sh <tag> [target] [extra xcodebuild settings...]
# Builds the probe into build/<tag>/<target>.app and prints its signature facts.
source "${0:A:h}/lib.sh"
app=$(build_probe "$@")
print -r -- "$app"
sig_info "$app"
