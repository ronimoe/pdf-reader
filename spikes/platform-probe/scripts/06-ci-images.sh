#!/bin/zsh
# Experiment 6: which GitHub-hosted macOS runner images offer macOS 26 and Xcode 27?
# Reads actions/runner-images through the GitHub API (needs `gh auth login`).
set -euo pipefail
repo=actions/runner-images
fetch() { gh api "repos/$repo/contents/$1" --jq .content | base64 -d; }

print "== README: macOS image labels"
fetch README.md | grep -E '^\| macOS' | sed -E 's/<br>!\[Endpoint Badge\]\([^)]*\)//; s/\[!\[deprecated\][^)]*\)\]\([^)]*\)/(deprecated)/'
fetch README.md | grep -E '^\[(macOS-26|xcode-27)' || true

for image in macos-26-arm64 xcode-27-arm64; do
  print "\n== images/macos/$image-Readme.md"
  doc=$(fetch "images/macos/$image-Readme.md")
  print -r -- "$doc" | grep -E '^- (OS Version|Image Version)'
  print -r -- "$doc" | awk '/^### Xcode/{f=1} f&&/^\| [0-9]/{print} /^#### Installed SDKs/{exit}'
done

print "\n== Xcode 27 announcement"
gh api "repos/$repo/issues/14404" --jq '"\(.title) (opened \(.created_at), state \(.state))"'
gh api "repos/$repo/issues/14404" --jq .body | grep -E 'Edit|image now uses|runs-on|preview' | head -8
