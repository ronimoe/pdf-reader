#!/bin/zsh
# Installs the latest Lectern release into /Applications, without Homebrew and without the
# one-time Open Anyway step:
#
#   curl -fsSL https://raw.githubusercontent.com/ronimoe/pdf-reader/main/scripts/install.sh | zsh
#
# Why there's no Gatekeeper step: Lectern is signed ad-hoc, not with a Developer ID, and
# Gatekeeper's first-launch check applies only to an app carrying the com.apple.quarantine mark
# (docs/spikes/m0c-platform.md §5). Browsers add that mark to what they download; curl doesn't, and
# neither does copying out of a DMG that has none. So the copy installed here opens like a build
# from source. What you trust is HTTPS to github.com/ronimoe/pdf-reader, as with a DMG downloaded
# by hand. The .sha256 comes from the same release, so it catches a damaged or cut-off download,
# not a malicious one; the signature and bundle identifier checks catch a broken or wrong app.
#
# What it does:
#  1. Checks for macOS 26 or later on Apple Silicon, and that Homebrew isn't managing Lectern.
#  2. Finds the latest release from the github.com/ronimoe/pdf-reader/releases/latest redirect.
#  3. Downloads Lectern-<version>.dmg and its .sha256 into a new temporary folder and compares the
#     DMG's SHA-256 with the published one.
#  4. Mounts the DMG read-only and hidden (no Finder window), copies Lectern.app into a hidden
#     folder beside the destination, and checks its bundle identifier and signature.
#  5. Moves any previous copy aside, moves the new one into place, then deletes the previous one.
#     If the move fails, the previous copy is put back.
#  6. Detaches the DMG and deletes everything temporary, also on failure and on Ctrl-C.
#
# It installs into /Applications, or ~/Applications when /Applications isn't writable. It never
# uses sudo, never opens the app, and refuses to replace a copy that is running.
#
# The whole script is one function called on the last line, so a download cut off halfway runs
# nothing. scripts/release/test-install checks it offline (scripts/test.sh runs that).
#
# Usage: scripts/install.sh            (or piped into zsh as above)
#   LECTERN_APPDIR=<folder>            install there instead (used by the tests)
#   LECTERN_VERSION=<x.y.z>            install that release instead of the latest

# Plain sh syntax, so `| sh` or `| bash` gets a clear message instead of a parse error.
if [ -z "${ZSH_VERSION:-}" ]; then echo "install: run this with zsh (curl … | zsh)" >&2; exit 1; fi

lectern_install() {
  # Local options and traps, whatever the user's zsh startup files set.
  emulate -L zsh
  setopt err_exit pipe_fail no_unset

  local repo=https://github.com/ronimoe/pdf-reader
  local bundle_id=io.github.ronimoe.Lectern

  say() { print -r -- "== $*"; }
  note() { print -r -- "note: $*"; }
  die() { print -r -- "install: $*" >&2; exit 1; }

  # 1. The system.
  local macos=$(sw_vers -productVersion)
  (( ${macos%%.*} >= 26 )) || die "Lectern needs macOS 26 (Tahoe) or later; this Mac has $macos"
  [[ $(sysctl -n hw.optional.arm64 2>/dev/null) == 1 ]] || die "Lectern needs an Apple Silicon Mac"
  local tool
  for tool in curl shasum hdiutil ditto codesign xattr plutil ps mktemp; do
    command -v $tool >/dev/null || die "$tool not found"
  done
  if command -v brew >/dev/null; then
    local caskroom="$(brew --prefix 2>/dev/null)/Caskroom/lectern"
    [[ -d $caskroom ]] && die "Homebrew manages Lectern on this Mac; update it with: brew upgrade --cask lectern"
  fi

  # Where to install. A leading ~ is expanded even when the value was quoted.
  local appdir=${LECTERN_APPDIR:-}
  appdir=${appdir/#\~/$HOME}
  if [[ -z $appdir ]]; then
    if [[ -w /Applications ]]; then appdir=/Applications; else appdir=$HOME/Applications; fi
  fi
  appdir=${appdir:A}
  local target=$appdir/Lectern.app

  # A copy running from the destination can't be replaced. Matched as a fixed string, so a path
  # with ( + . or [ in it is compared literally.
  refuse_if_running() {
    local process
    for process in ${(f)"$(ps -axo command=)"}; do
      [[ $process == "$target/Contents/MacOS/"* ]] && die "Lectern is running from $target; quit it, then run this again"
    done
    return 0
  }
  refuse_if_running
  if [[ $target != /Applications/Lectern.app && -e /Applications/Lectern.app ]]; then
    note "another copy stays in /Applications; this one goes to $appdir"
  fi

  # 2. The version.
  local version=${LECTERN_VERSION:-}
  if [[ -z $version ]]; then
    local latest
    latest=$(curl -fsSLI --proto '=https' --proto-redir '=https' -o /dev/null -w '%{url_effective}' "$repo/releases/latest") \
      || die "couldn't reach $repo/releases/latest"
    version=${latest##*/tag/}
  fi
  version=${version#v}
  [[ $version =~ '^[0-9]+(\.[0-9]+)*$' ]] || die "unexpected version '$version'"
  say "Lectern $version into $appdir"

  # Everything temporary: downloads and the mount point in $tmp, the new copy and the previous one
  # in $work, a hidden folder beside the destination so the final moves stay on one volume. The
  # trap is built with ${(q)…}, so the paths are quoted for the shell whatever they contain.
  mkdir -p -- "$appdir" || die "couldn't create $appdir"
  local tmp work
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lectern-install.XXXXXX") || die "couldn't create a temporary folder"
  work=$(mktemp -d "$appdir/.lectern-install.XXXXXX") || { rm -rf -- "$tmp"; die "couldn't write to $appdir"; }
  local mnt=$tmp/mnt
  trap "hdiutil detach ${(q)mnt} -quiet -force >/dev/null 2>&1 || true
        if [[ -e ${(q)work}/previous.app && ! -e ${(q)target} ]]; then mv -- ${(q)work}/previous.app ${(q)target}; fi
        rm -rf -- ${(q)tmp} ${(q)work}" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # 3. Download and compare checksums.
  local dmg=Lectern-$version.dmg name
  say "download $dmg"
  for name in $dmg $dmg.sha256; do
    curl -fsSL --proto '=https' --proto-redir '=https' -o "$tmp/$name" "$repo/releases/download/v$version/$name" \
      || die "couldn't download $name"
  done
  local published= actual
  read -r published _ < "$tmp/$dmg.sha256" || true
  [[ $published =~ '^[0-9a-f]{64}$' ]] || die "$dmg.sha256 doesn't hold a SHA-256; nothing was installed"
  actual=$(shasum -a 256 "$tmp/$dmg") || die "couldn't read $dmg"
  [[ ${actual%% *} == $published ]] || die "$dmg doesn't match its published SHA-256; nothing was installed"
  say "checksum OK"

  # 4. Copy the app out of the read-only, hidden mount and check it before replacing anything.
  mkdir -- "$mnt"
  hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$mnt" "$tmp/$dmg" -quiet < /dev/null \
    || die "couldn't mount $dmg"
  [[ -d $mnt/Lectern.app ]] || die "$dmg has no Lectern.app"
  ditto -- "$mnt/Lectern.app" "$work/Lectern.app" || die "couldn't copy Lectern.app out of $dmg"
  hdiutil detach "$mnt" -quiet < /dev/null || true
  local id
  id=$(plutil -extract CFBundleIdentifier raw "$work/Lectern.app/Contents/Info.plist" 2>/dev/null) || id=
  [[ $id == $bundle_id ]] || die "the app in $dmg has bundle identifier '$id', expected $bundle_id"
  codesign --verify --deep --strict "$work/Lectern.app" 2>/dev/null || die "the app in $dmg failed its signature check"
  xattr -dr com.apple.quarantine "$work/Lectern.app" 2>/dev/null || true

  # 5. Swap: previous copy aside, new copy in, previous copy deleted. Checked for a running copy
  # again, since the download took a while.
  refuse_if_running
  if [[ -e $target ]]; then
    mv -- "$target" "$work/previous.app" \
      || die "couldn't move the previous copy aside. If macOS refused, drag $target to the Trash and run this again"
  fi
  if ! mv -- "$work/Lectern.app" "$target"; then
    [[ -e $work/previous.app ]] && mv -- "$work/previous.app" "$target"
    die "couldn't move Lectern.app into $appdir; any previous copy was put back"
  fi
  say "installed $target"
  print -r -- "Open Lectern from $appdir, or run: open ${(q)target}"
}

lectern_install "$@"
