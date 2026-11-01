# Installing Lectern

Lectern needs **macOS 26 (Tahoe) or later on an Apple Silicon Mac**.

Lectern isn't signed with an Apple Developer ID ([why](#why-isnt-it-signed)). A copy downloaded in a browser is therefore blocked the first time you open it, and you have to allow it once. The Terminal line and Homebrew avoid that step. Each route below says how.

## One line in Terminal

The quickest way, with no Homebrew and no Open Anyway step:

```sh
curl -fsSL https://raw.githubusercontent.com/ronimoe/pdf-reader/main/scripts/install.sh | zsh
```

- **What it does.** [`scripts/install.sh`](../scripts/install.sh) downloads the latest DMG from this project's GitHub Releases. It compares it with the SHA-256 published with that release, checks the app's signature and bundle identifier, and moves it into `/Applications`, or `~/Applications` if you can't write to `/Applications`. Any older copy is replaced, and put back if the move fails; if even that fails, it tells you where the older copy is. Everything temporary is deleted, even if you press Ctrl-C, and anything it can't delete is named so you can move it to the Trash. It never uses `sudo` and never opens the app. Read it first if you like.
- **Why macOS doesn't ask.** Gatekeeper's first-launch check applies only to an app carrying the "downloaded from the internet" mark. Browsers add that mark; `curl` doesn't. So this copy opens like one you built yourself.
- **What you're trusting** is HTTPS to this project's GitHub repository: for the DMG, as when you download it yourself, and for the script, which is fetched from `main` each time. The checksum comes from the same release, so it catches a damaged or cut-off download, not a malicious one. Run the line only as written here.
- **It stops instead of guessing** if Lectern is running from where it would install (quit it first), or if Homebrew installed Lectern (use `brew upgrade --cask lectern`).
- **Updating.** Run the same line again (quit Lectern first), or use the in-app update check ([Updates](#updates)).

## Homebrew

```sh
brew tap ronimoe/lectern
brew install --cask ronimoe/lectern/lectern
```

- **If Homebrew refuses the tap as untrusted,** run `brew trust --cask ronimoe/lectern/lectern` and install again. Homebrew requires this for taps outside its own.
- **No Gatekeeper step.** Homebrew marks what it installs as downloaded (quarantined). The cask removes that mark from `Lectern.app` right after installing, so you don't need the steps in the DMG section. This is why Lectern lives in its own tap: Homebrew's main cask repository doesn't accept apps that need it.
- **Updating.** `brew upgrade --cask lectern` (or plain `brew upgrade`) updates it. See [Updates](#updates).

## Download (DMG)

1. Download `Lectern-<version>.dmg` from the project's GitHub Releases page. Next to it is `Lectern-<version>.dmg.sha256`. To check the download, run `shasum -a 256 -c Lectern-<version>.dmg.sha256` in the folder that holds both files.
2. Open the DMG. Its window shows Lectern and an arrow to Applications: drag **Lectern** onto **Applications**.
Steps 3 and 4 are based on Apple's documented flow for macOS 15 and later; they haven't been walked through with Lectern on macOS 26.

3. Open Lectern from Applications. macOS shows a "Not Opened" alert saying Apple could not verify that Lectern is free of malware. There is no Open button. Click **Done**, not Move to Trash.
4. Open **System Settings → Privacy & Security** and scroll to **Security**. Next to the message about Lectern, click **Open Anyway**. The button appears for about an hour after step 3. Enter your login password, then click **Open**.

**Or, instead of steps 3 and 4,** run this in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Lectern.app
```

This removes the "downloaded from the internet" mark from the app, and macOS then opens it without asking.

- **The caveat.** That mark is what makes macOS check an app before its first launch. Removing it by hand skips the check for this copy entirely, so do it only for a copy you trust: one you downloaded from the project's own GitHub Releases page and whose checksum matched in step 1. Never run it on an app you got anywhere else.

- **You do this once per downloaded copy.** Updates that Lectern installs itself (see [Updates](#updates)) arrive without the "downloaded" mark, so they don't need it again. A new DMG you download by hand does.
- **Control-click → Open no longer works.** Since macOS 15 it doesn't bypass the check; use one of the routes above.
- **The DMG includes `Read Me First.txt`** with the same steps.

## Updates

Lectern never goes online on its own unless you say so. There are three ways to update:

- **In the app (opt-in).** Turn on automatic checks, or use Check Now, as described below.
- **With Homebrew.** `brew upgrade --cask lectern` installs the newest release, whether or not the in-app check is on. Homebrew doesn't rely on the in-app updater, because it's off by default.
- **With the Terminal line.** Quit Lectern and run the [same line](#one-line-in-terminal) again.

### The in-app update check

- **On first launch** it asks once whether to check for updates automatically. The default answer is no. Change it any time in **Lectern ▸ Settings… ▸ Updates**.
- **If you turn it on,** Lectern checks GitHub for a newer release at most once a day and asks before installing anything. **Check Now** in Settings (or **Lectern ▸ Check for Updates…**) checks once, whatever the setting.
- **What is sent.** Only the request for the release feed. No analytics, crash reports or usage data, ever.
- **How updates are trusted.** Every update is signed with the project's EdDSA key, and Lectern refuses one that isn't. The app's ad-hoc code signature changes with every build, so this signature is what identifies a real update.
- **A new DMG by hand** works too: quit Lectern, replace the app in Applications, and allow it once as in the DMG steps.

### After an update: the Keychain may ask once

If you ticked **Remember in Keychain** for a PDF's password, the first time an updated Lectern opens that PDF macOS may ask whether Lectern can use the saved password. That's because each build has a different signature ([why](#why-isnt-it-signed)). Click **Always Allow** to let the new version use it, or **Deny** and type the password once more; Lectern treats a denied or failed read as "not saved" and asks for the password. Nothing is lost either way.

## Build from source

You need Xcode 27 (Xcode 27.1 is what the project is built and tested with), Homebrew and access to the repository.

```sh
git clone https://github.com/ronimoe/pdf-reader.git
cd pdf-reader
brew install xcodegen
xcodegen generate
xcodebuild -project Lectern.xcodeproj -scheme Lectern -configuration Release -derivedDataPath build/DerivedData build
rm -rf /Applications/Lectern.app
ditto build/DerivedData/Build/Products/Release/Lectern.app /Applications/Lectern.app
```

- **Quit Lectern before the last two lines.** They replace any copy already in Applications.
- **No Gatekeeper step.** An app you build yourself isn't marked as downloaded, so it opens normally.

### Developer notes: release scripts

- **`scripts/release/build-dmg`** makes a clean Release build, checks its ad-hoc signature and entitlements, and writes `build/release/Lectern-<version>.dmg` with its `.sha256`. The DMG appears only after `hdiutil verify` passes. Its window layout lives in `packaging/dmg/`: `layout.json` holds the positions, `make-background.swift` draws the background, and dmgbuild (1.6.7, run through `uvx` with its libraries and Python pinned) writes the image. Nothing opens a Finder window while building.
- **`scripts/release/verify-dmg`** checks that DMG: checksum, contents (including `License.txt` and `Acknowledgements.txt`), the window layout it tells Finder to use (which can only be checked by eye by opening the DMG), signature and entitlements of a copied app, and `spctl` on quarantined copies, which are never opened. It then runs the copy's **headless self-check**: the app's executable started directly with `-LecternSelfCheck`, which checks the bundle, Sparkle, the entitlements and sandbox of the running process, and the PDF engine on a document made in memory, then exits before any window, Dock icon or alert can exist. It runs inside your real Lectern sandbox container, but it opens no document and never touches `Session.json`, the crash journal, recent documents, the Keychain or Sparkle (which it never creates). It refuses to run while Lectern is running.
- **`scripts/release/build-dmg`** also writes `build/release/Lectern-<version>.zip`, the update archive for the in-app updater.
- **`scripts/release/sign-update <zip>`** signs that archive with the EdDSA key in `~/.config/lectern/sparkle_ed25519_private.key` and adds it to `build/release/appcast.xml`. It refuses a key whose public half isn't the app's `SUPublicEDKey`. Upload the zip and `appcast.xml` to the GitHub release; the app reads `releases/latest/download/appcast.xml`. **Keep the key file backed up offline:** without it, installed copies can never be updated by the app again.
- **`swift scripts/release/sparkle-key.swift generate <file>`** makes a new key file (mode 600) without using the Keychain, and prints the public key. It refuses to overwrite a key. Only needed once.
- **`scripts/release/sparkle-e2e`** proves, without any window, that the updater installs one ad-hoc build over another and refuses an update signed with a different key. It builds a small headless test app and installs it in a temporary folder.
- **`scripts/release/update-cask`** writes the version and checksum of a DMG into the cask. It refuses a DMG without a matching `.sha256`. **`scripts/release/check-cask`** runs `brew style` and `brew audit` on the cask in a throwaway local tap.
- **`scripts/install.sh`** is the [Terminal installer](#one-line-in-terminal). People run it straight from `main`, so a change to it is live as soon as it's merged, and it must keep working with the latest release's file names. Try it without touching `/Applications` with `LECTERN_APPDIR=<folder> zsh scripts/install.sh`; `LECTERN_VERSION=<x.y.z>` picks a release. **`scripts/release/test-install`** (run by `scripts/test.sh`) checks it offline, piped into `zsh` as people run it, against fixture releases served by a fake `curl`. It covers checksum, signature and bundle-identifier failures; replacing an older copy whole and putting it back when a move fails; a copy running before or during the download; a Homebrew copy; Ctrl-C and TERM; an alias in `~/.zshenv`; a quarantined app; a cut-off download; and a destination with quotes and spaces. It never launches an app or shows an image in Finder.
- **`scripts/perf.sh`** runs the performance tests on the representative documents ([performance.md](performance.md)); `scripts/test.sh` skips them.
- **Publishing** a release is a manual checklist: [release-checklist.md](release-checklist.md).

## Uninstall

1. Quit Lectern.
2. Remove the app:
   - **Homebrew:** `brew uninstall --cask ronimoe/lectern/lectern`
   - **Otherwise:** drag `Lectern.app` from `/Applications` (or `~/Applications`, where the Terminal line installs it if it can't write to `/Applications`) to the Trash, then empty the Trash.

Removing the app leaves your reading data behind. Lectern is sandboxed, so all of it is in two folders:

| Location | What's there |
|---|---|
| `~/Library/Containers/io.github.ronimoe.Lectern` | Everything Lectern stores: reading positions, reader bookmarks, history, view settings, the list of windows to reopen, and preferences |
| `~/Library/Application Scripts/io.github.ronimoe.Lectern` | An empty folder macOS creates for every sandboxed app |

- **Removing the data.** Quit Lectern first. Your reading data is in the `Data` folder inside the container. macOS protects the container folder itself, so it may refuse to delete it, and it may ask whether Terminal or Finder can access another app's data.
- **With Homebrew,** `brew uninstall --zap --cask ronimoe/lectern/lectern` removes the app and tries to move both folders to the Trash (the cask's `zap` step). This hasn't been tried end to end yet; check the two folders afterwards.
- **Saved PDF passwords.** These exist only if you ticked "Remember in Keychain". Open Keychain Access and delete the items named `io.github.ronimoe.Lectern.document-password`.
- **Your PDFs** are never moved or copied into these folders. Annotations you save are written into the PDF file itself.

## Why isn't it signed?

Signing an app with a Developer ID and having Apple notarize it needs a paid Apple Developer Program membership, which this project doesn't have. Lectern is distributed without one:

- **What it is signed with.** The app has an *ad-hoc* signature: it proves the files haven't changed since the build, but not who built it. It also runs with the hardened runtime and in the App Sandbox, which limits what a malicious PDF could reach.
- **Checking a copy yourself.** `codesign -dv --entitlements - /Applications/Lectern.app` shows the signature and the sandbox entitlements. Compare the DMG against its `.sha256` file before opening it.
- **Gatekeeper.** Unsigned and un-notarized apps are blocked on first open, which is why each route above has one deliberate step. Building from source avoids it.
- **Saved passwords after an update.** Every build has a different signature. When a new version first reads a PDF password that an older one saved in the Keychain, macOS may ask whether to allow it. If you decline, Lectern asks for the document's password instead.

With a Developer ID and notarization, the Gatekeeper step and the Keychain question would no longer be needed.
