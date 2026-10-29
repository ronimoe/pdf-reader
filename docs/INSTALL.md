# Installing Lectern

Lectern needs **macOS 26 (Tahoe) or later on an Apple Silicon Mac**.

> **Not published yet.** There is no public release, GitHub Release download or Homebrew tap yet, so only [building from source](#build-from-source) works today. The other two sections describe how installing will work once a release is published.

Lectern isn't signed with an Apple Developer ID ([why](#why-isnt-it-signed)). macOS therefore blocks a downloaded copy the first time you open it, and you have to allow it once. Each route below says how.

## Homebrew (not yet published)

```sh
brew tap ronimoe/lectern
brew install --cask ronimoe/lectern/lectern
```

- **If Homebrew refuses the tap as untrusted,** run `brew trust --cask ronimoe/lectern/lectern` and install again. Homebrew requires this for taps outside its own.
- **No Gatekeeper step.** Homebrew marks what it installs as downloaded (quarantined). The cask removes that mark from `Lectern.app` right after installing, so you don't need the steps in the DMG section. This is why Lectern lives in its own tap: Homebrew's main cask repository doesn't accept apps that need it.
- **Updating.** The cask is marked `auto_updates`, so a plain `brew upgrade` skips Lectern. Lectern doesn't update itself yet, so to update run:

  ```sh
  brew upgrade --cask --greedy ronimoe/lectern/lectern
  ```

## Download (DMG) (not yet published)

1. Download `Lectern-<version>.dmg` from the project's GitHub Releases page. Next to it is `Lectern-<version>.dmg.sha256`. To check the download, run `shasum -a 256 -c Lectern-<version>.dmg.sha256` in the folder that holds both files.
2. Open the DMG and drag **Lectern** onto **Applications**.
3. Open Lectern from Applications. macOS shows a "Not Opened" alert saying Apple could not verify that Lectern is free of malware. There is no Open button. Click **Done**, not Move to Trash.
4. Open **System Settings → Privacy & Security** and scroll to **Security**. Next to the message about Lectern, click **Open Anyway**. The button appears for about an hour after step 3. Enter your login password, then click **Open**.

**Or, instead of steps 3 and 4,** run this in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Lectern.app
```

This removes the "downloaded from the internet" mark from the app, and macOS then opens it without asking.

- **You do this once per downloaded copy.** Lectern has no built-in updater yet, so each new version you download needs it again.
- **Control-click → Open no longer works.** Since macOS 15 it doesn't bypass the check; use one of the routes above.
- **The DMG includes `Read Me First.txt`** with the same steps.

## Build from source

You need Xcode 27 (Xcode 27.1 is what the project is built and tested with), Homebrew and access to the repository.

```sh
git clone https://github.com/ronimoe/pdf-reader.git
cd pdf-reader
brew install xcodegen
xcodegen generate
xcodebuild -project Lectern.xcodeproj -scheme Lectern -configuration Release -derivedDataPath build/DerivedData build
ditto build/DerivedData/Build/Products/Release/Lectern.app /Applications/Lectern.app
```

- **No Gatekeeper step.** An app you build yourself isn't marked as downloaded, so it opens normally.
- **A DMG instead.** `scripts/release/build-dmg` builds the same Release app, checks its signature and entitlements, and writes `build/release/Lectern-<version>.dmg` with its `.sha256`. `scripts/release/verify-dmg` then checks that DMG.

## Uninstall

1. Quit Lectern.
2. Remove the app:
   - **Homebrew:** `brew uninstall --cask ronimoe/lectern/lectern`
   - **Otherwise:** drag `/Applications/Lectern.app` to the Trash.

Removing the app leaves your reading data behind. Lectern is sandboxed, so all of it is in two folders:

| Location | What's there |
|---|---|
| `~/Library/Containers/io.github.ronimoe.Lectern` | Everything Lectern stores: reading positions, reader bookmarks, history, view settings and preferences |
| `~/Library/Application Scripts/io.github.ronimoe.Lectern` | An empty folder macOS creates for every sandboxed app |

- **Removing the data.** Delete the `Data` folder inside the container, for example with `rm -rf ~/Library/Containers/io.github.ronimoe.Lectern/Data`. macOS protects the container folder itself, so Terminal can't delete it; what's left after removing `Data` holds no reading data.
- **With Homebrew,** `brew uninstall --zap --cask ronimoe/lectern/lectern` tries to move both folders to the Trash.
- **Saved PDF passwords.** These exist only if you ticked "Remember in Keychain". Open Keychain Access and delete the items named `io.github.ronimoe.Lectern.document-password`.
- **Your PDFs** are never moved or copied into these folders. Annotations you save are written into the PDF file itself.

## Why isn't it signed?

Signing an app with a Developer ID and having Apple notarize it needs a paid Apple Developer Program membership, which this project doesn't have. Lectern is distributed without one:

- **What it is signed with.** The app has an *ad-hoc* signature: it proves the files haven't changed since the build, but not who built it. It also runs with the hardened runtime and in the App Sandbox, which limits what a malicious PDF could reach.
- **Checking a copy yourself.** `codesign -dv --entitlements - /Applications/Lectern.app` shows the signature and the sandbox entitlements. Compare the DMG against its `.sha256` file before opening it.
- **Gatekeeper.** Unsigned and un-notarized apps are blocked on first open, which is why each route above has one deliberate step. Building from source avoids it.
- **Saved passwords after an update.** Every build has a different signature. When a new version first reads a PDF password that an older one saved in the Keychain, macOS may ask whether to allow it. If you decline, Lectern asks for the document's password instead.

With a Developer ID and notarization, the Gatekeeper step and the Keychain question would no longer be needed.
