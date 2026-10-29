# Release checklist

How to publish Lectern 1.0.0, and the checks still owed by hand. Everything below is a decision or an action for the maintainer: the automated build stops at local files, and nothing has been published, tagged or pushed to a tap.

The names here are fixed by what's already built: the cask downloads `https://github.com/ronimoe/pdf-reader/releases/download/v1.0.0/Lectern-1.0.0.dmg`, the appcast's enclosure is `…/releases/download/v1.0.0/Lectern-1.0.0.zip`, and the app reads its feed from `https://github.com/ronimoe/pdf-reader/releases/latest/download/appcast.xml`. So the tag must be **`v1.0.0`** and the assets must keep their names.

## 0. What's already built (local only)

In `build/release/` (git-ignored) of the worktree where M6 was built, from `scripts/release/build-dmg`. These are local test outputs, not the files to publish:

| File | What it is |
|---|---|
| `Lectern-1.0.0.dmg` | The disk image: Lectern.app, an Applications link, `Read Me First.txt`, `License.txt`, `Acknowledgements.txt` |
| `Lectern-1.0.0.dmg.sha256` | Its checksum, in `shasum -a 256 -c` format |
| `Lectern-1.0.0.zip` | The Sparkle update archive (the same app) |
| `appcast.xml` | The update feed, with the zip's EdDSA signature |
| `verify-1.0.0.txt` | `verify-dmg`'s report |
| `signature.txt` | The app's signature and entitlements |

**Rebuild from the final merged commit before publishing.** The cask's sha256 in `packaging/homebrew/Casks/lectern.rb` refers to that local DMG, which exists only on the build machine and is git-ignored, and every build has a different checksum. So on the commit you release:

1. `scripts/release/build-dmg` and `scripts/release/verify-dmg`;
2. `scripts/release/update-cask`, then `scripts/release/check-cask`;
3. `scripts/release/sign-update build/release/Lectern-1.0.0.zip`, which rewrites `appcast.xml`;
4. commit the cask (that commit changes no app code, so the DMG still matches it), and publish exactly those files.

Before publishing, re-run the gates on the commit you're releasing:

```sh
scripts/test.sh            # twice in a row, as for every milestone
scripts/perf.sh
scripts/release/build-dmg && scripts/release/verify-dmg
scripts/release/update-cask && scripts/release/check-cask
scripts/release/sign-update build/release/Lectern-1.0.0.zip
```

## 1. Back up the Sparkle private key (do this first)

`~/.config/lectern/sparkle_ed25519_private.key` (mode 600) signs every update. **If it's lost, copies already installed can never be updated by the app again**; users would have to download a new DMG by hand.

- Copy it to offline storage you control (an encrypted USB drive, a password manager's secure file, or both).
- Check the backup: `swift scripts/release/sparkle-key.swift public <backup file>` must print the same key as `SUPublicEDKey` in `App/Info.plist`.
- Never commit it, never upload it to a release.

## 2. Make the downloads reachable

The repository is private, so release assets and the cask's URL work for nobody else. Choose one:

- **Make `ronimoe/pdf-reader` public** (Settings ▸ General ▸ Danger Zone ▸ Change visibility). Check first that nothing private is in the history; everything in `Tests/Corpus/public/` is redistributable (see its README).
- **Or host the files elsewhere.** Then change the cask's `url`, the `--url` passed to `sign-update`, and `SUFeedURL` in `App/Info.plist` (which needs a rebuild, since the feed URL is inside the app).

## 3. Tag and create the GitHub Release

```sh
git tag -a v1.0.0 -m "Lectern 1.0.0" <release commit>
git push origin v1.0.0
gh release create v1.0.0 --title "Lectern 1.0.0" --notes-file <notes> \
  build/release/Lectern-1.0.0.dmg build/release/Lectern-1.0.0.dmg.sha256 \
  build/release/Lectern-1.0.0.zip build/release/appcast.xml
```

- Use the 1.0.0 section of `CHANGELOG.md` for the notes, plus a link to `docs/INSTALL.md` and `docs/known-limitations.md`.
- **Not a draft and not a pre-release.** `releases/latest/download/appcast.xml` only resolves to the latest *published, full* release; a draft or pre-release breaks in-app updates.
- After publishing, check from another machine or a private browser window that the four URLs download, and that `shasum -a 256 -c Lectern-1.0.0.dmg.sha256` passes on the download.

## 4. Create the Homebrew tap

1. Create the public repository **`ronimoe/homebrew-lectern`** (Homebrew finds `brew tap ronimoe/lectern` there).
2. Add `packaging/homebrew/Casks/lectern.rb` from this repository as `Casks/lectern.rb`, commit and push.
3. Test on a Mac without Lectern: `brew tap ronimoe/lectern && brew install --cask ronimoe/lectern/lectern`. If Homebrew asks, `brew trust --cask ronimoe/lectern/lectern` (whether a GitHub-hosted tap needs it is unverified).
4. Check Lectern opens with no Gatekeeper prompt (the cask removes the quarantine).
5. For later releases, copy the updated cask into the tap after `update-cask`.

## 5. Manual checks still owed

None of these can be done headlessly; the automated suites cover what they can (see [acceptance.md](acceptance.md)). Do them on the released build, ideally on the baseline machine.

| Check | How | From |
|---|---|---|
| **Performance on a base M1 with 8 GB** (A6) | `scripts/perf.sh` on that Mac; adjust the thresholds in `AppTests/M6/RepresentativePerformanceTests.swift` and [performance.md](performance.md) from its numbers. Watch especially the 0.73 s main-thread save on the 3,270-page manual, and the footprint in Activity Monitor while reading through that manual on screen | M6 |
| **Open Anyway** | Download the DMG in Safari, drag to Applications, open, click Done, then System Settings ▸ Privacy & Security ▸ Open Anyway | M0c, M6a |
| **The live first-launch alert** | On a clean account, first launch asks once about update checks; "Don't Check" is the default | M5 |
| **Sparkle's own windows, HTTPS from GitHub** | With 1.0.0 installed and checks on, publish a 1.0.1 (build 2) and let the app find, download and install it from GitHub; a wrongly signed archive must be refused | M0c, M5 |
| **VoiceOver** | Open a paper; move through the toolbar, sidebar, link focus (⌥⇥), annotation list and Settings with VoiceOver on; a scanned PDF should say it has no readable text | M0b–M5 |
| **Real hover and Force Click** | Hover a citation for 0.5 s; Force Click a figure reference; neither moves your place | M0b, M3 |
| **The Tab guard with a real keyboard** | In `irs-fw9.pdf`, press Tab: focus must not enter a form field | M4b |
| **Preview and Acrobat Reader** | Save highlights and a note into a copy of an arXiv paper and the IRS W-9 copy; open both in Preview and Acrobat Reader; the annotations show and the form values are unchanged | M0a, M4a |
| **An encrypted saved file in Preview and Acrobat Reader** | Open `Tests/Corpus/public/encrypted-aes256.pdf` (password `user-pass`) and `encrypted-r4-aes128-objstm.pdf` (`user-pass`) in Lectern, add a highlight and a note, ⌘S. Open each saved file in Preview and in Acrobat Reader: both must ask for the password, accept `user-pass`, and show the highlight and the note with their text. Also `encrypted-r2-rc4-40.pdf` (`user-pass`, RC4) in Acrobat Reader | M7 |
| **In-place save under the sandbox** | Open a PDF from your Documents folder, highlight, ⌘S, reopen | M4b |
| **Session restore across a real relaunch** | Open two windows with tabs and a split, quit, relaunch; also with a file from another volume | M5 |
| **A cancelled quit through AppKit's real prompt** | Make an unsaved highlight, ⌘Q, Cancel; the session must still be saved on the next quit | M5 |
| **The cask's `zap`** | `brew uninstall --zap --cask ronimoe/lectern/lectern`; both folders listed in INSTALL.md are gone or in the Trash | M6a |
| **Real drag-and-drop** | Drag a PDF onto the Dock icon and onto a window; drag across text to select | M1, M4b |
| **The sandbox refuses reads outside the container** | In a normally launched copy, open a PDF, then check Console for a `Sandbox: Lectern deny file-read-data` line when it touches anything you didn't open; the headless self-check, started directly from a shell, was able to read files in the home folder (architecture §8) | M6 |
| **The Keychain prompt after an update** | Remember a password, update, reopen the PDF; expect one Keychain question (B6) | M0c |

Record the outcome of each in `docs/progress.md` (or a release note), and move anything that fails into `docs/known-limitations.md`.

## 6. After publishing

- Turn `README.md`'s "Not published yet" status into the release link, and drop the banner at the top of `docs/INSTALL.md`.
- Clean up from M0c if you haven't: the Sparkle test key (`lectern-m0c-probe`) in the login Keychain.
