# M0c: Platform spike (ad-hoc signing, sandbox, updates, install)

**Question.** Lectern ships without a Developer ID, signed ad-hoc, sandboxed, with the hardened runtime (architecture.md §6, §8; decisions A2, A4, B5, B6). What actually works on macOS 26 when every release is a differently signed binary? These results decide whether the sandbox stays on and whether Sparkle stays in v1.

**Setup**
- **Machine.** macOS 26.6.2 (25G83), Apple Silicon, Xcode 27.1 (27A9275), XcodeGen 2.46.0, Homebrew 7.0.11, Sparkle 2.10.1. Run on 2026-10-29.
- **Branch.** `m0c-platform` was branched from `m0-skeleton` (`af0845d`). The worktree had been created one commit earlier, at `e1d9b19`, which has no `App/Lectern.entitlements`.
- **The probe.** `spikes/platform-probe/` is a standalone app, `io.github.ronimoe.PlatformProbe`:
  - It has the same entitlements as `App/Lectern.entitlements` (sandbox, user-selected read-write, app-scoped bookmarks, network client).
  - It uses the same ad-hoc signing and hardened runtime, and the same PDF document type (rank Alternate).
  - It is headless. Each launch runs one mode (`--mode …`) and writes a JSON result into its container after every step.
- **Builds.** "v1" and "v2" differ by a compiled code change (`PROBE_V2`) and `CFBundleVersion` 1 → 2. The CDHash therefore differs, and so does the ad-hoc designated requirement (`cdhash H"…"`), exactly as it will between two Lectern releases.
- **Scripts.** `spikes/platform-probe/scripts/NN-*.sh`; raw output and per-run JSON are in `spikes/platform-probe/results/`. `scripts/cleanup.sh` undoes everything the experiments leave behind.
- **Steps that put a dialog on screen only run when asked.** Launching quarantined copies needs `GK_LAUNCH_QUARANTINED=1`, and interactive Keychain reads by v2 need `KC_INTERACTIVE=1`. The recorded runs had both set; reruns default to non-GUI checks.
- **Dialog detection.** Each run checks for on-screen windows owned by SecurityAgent, UserNotificationCenter or CoreServicesUIAgent, using `scripts/onscreen-windows.swift`, and takes excerpts from the system log.
- **Caveat on human input.** Someone was at the Mac during the run. They answered one Keychain prompt ("Always Allow"), chose "Move to Trash" on two Gatekeeper alerts, and reported the alert's text. Where that affected a result, it's noted below.

**Every update is a re-sign.** Ad-hoc signatures have no stable identity: the designated requirement is the CDHash. Whatever breaks between v1 and v2 below breaks for every user on every Lectern release, whether it arrives by DMG, `brew upgrade` or Sparkle.

---

## 1. Security-scoped bookmarks across rebuilds

**Result: works.** A bookmark created by v1 resolves in v2 and gives read access. It follows renames and moves.

**Evidence** (`scripts/01-bookmarks.sh`, `results/01-bookmarks.txt`, `results/bm-*.json`). The test PDF lived in `~/PlatformProbeFixtures/`, outside the container and outside Desktop, Documents and Downloads.

| Run | Build | Plain `open(2)` of the path (control) | Resolve | `isStale` | Read through bookmark |
|---|---|---|---|---|---|
| `open -a v1.app file.pdf`, create bookmark | v1 | n/a (open event) | n/a | n/a | ok (346 bytes) |
| Relaunch, no file | v1 | EPERM | ok | false | ok |
| Relaunch, no file | **v2** | EPERM | **ok** | false | **ok** |
| File renamed in place | v2 | EPERM | ok, new path | true | ok, refreshed |
| File moved to `moved/deeper/` | v2 | EPERM | ok, new path | true | ok, refreshed |
| Back to v1, using v2's refreshed bookmark | v1 | EPERM | ok | false | ok |

The EPERM control shows the sandbox really blocks the path, so access came from the bookmark. No dialogs appeared.

**Consequence**
- A2's primary identity (a security-scoped bookmark) survives updates and moves.
- Lectern must refresh the stored bookmark whenever `isStale` is true, while it holds access, the way the probe does.

## 2. The sandbox container across rebuilds

**Result: works, silently.** v2 reads and writes everything v1 left in the container, and the reverse also works. No dialog appears.

**Evidence** (`scripts/02-container.sh`, `results/02-container.txt`, `results/ct-*.json`, `results/logs-ct-3-read-v2.txt`)
- **Reads and writes both ways.** v1 wrote a marker file and a `UserDefaults` value. v2 read both (`writtenBy: v1`) and wrote a new file. v2 then wrote, and v1 read `writtenBy: v2`.
- **No dialog or permission request.** No dialog window appeared. tccd logged no `kTCCServiceSystemPolicyAppData` ("access data from other apps") request.
- **containermanagerd updated silently.** It rewrote `.com.apple.containermanagerd.metadata.plist` just before v2 started, with no prompt.
- **The container is protected from the shell.**
  - `.com.apple.containermanagerd.metadata.plist` can't be read from the shell (permission denied).
  - The container root can't be deleted (`rm` gets EPERM, and the kernel logs "System Policy … deny file-write-unlink"). Only `Data/` can be removed.
  - Creating `~/Library/Containers/<id>` by hand makes containermanagerd claim it immediately, so scripts must never pre-create it.
- **Caveat.** This shell can read other apps' containers, which suggests a Full Disk Access–like grant. That doesn't affect the result, because the probe itself did the reads, but shell-side reads aren't representative of a user's Terminal.
- **The probe's own identity was checked.** TCC credits the probe processes to themselves, not to this session (`results/logs-tcc-attribution.txt`, from `scripts/tcc-attribution.sh`: `accessing=io.github.ronimoe.PlatformProbe`, with no `responsible=` parent). So "no dialog" isn't borrowed from the shell's permissions.
- **Independent corroboration.** In experiment 4, Sparkle relaunched v2 (not this shell), and v2 wrote into the existing container.

**Consequence**
- §6 storage (per-document JSON, the crash journal, `UserDefaults`) survives updates with no user-visible effect.

## 3. The Keychain across rebuilds

**Result: doesn't survive a rebuild without a prompt.** An item created by v1 can't be read by v2 unless the user answers a SecurityAgent prompt, on every update and for every item. The data protection keychain isn't available at all.

**Evidence** (`scripts/03-keychain.sh`, `03b-…`, `03c-…`, `results/03*.txt`, `results/kc*-*.json`, `results/logs-keychain-securityd.txt`)

| Case | v1 writes | v1 reads (control) | v2 reads, UI forbidden | v2 reads, UI allowed |
|---|---|---|---|---|
| Legacy login keychain, default ad-hoc DR | 0 | 0, no prompt | **-25293** (`errSecAuthFailed`) | SecurityAgent prompt shown. Someone clicked "Always Allow" after 9 s, then status 0 |
| Same, both builds re-signed with DR `identifier "io.github.ronimoe.PlatformProbe"` | 0 | n/a | **-25293** | Prompt shown. Unanswered for 25 s, then the probe was killed. The orphaned prompt stayed on screen until its SecurityAgent was killed |
| Same, **sandbox off** (attribution control) | 0 | 0 | **-25293** | not run (would prompt) |
| Data protection keychain (`kSecUseDataProtectionKeychain`) | **-34018** "A required entitlement isn't present" | -25300 | -25300 | n/a |

- **Why it prompts.** securityd says it directly:

  > ACL partition mismatch: client cdhash:cabadc83… ACL ("cdhash:227d378e…") … asking user about XARA partition

  For an app with no Team ID, the item's partition list is the creating binary's CDHash. A designated requirement based on the identifier doesn't help, and neither does turning the sandbox off.
- **Stable alternatives need a certificate.** The partition is `teamid:…` only for Apple-issued certificates. The data protection keychain needs `keychain-access-groups`, which needs a provisioning profile and a Team ID.
- **Sparkle's own tools hit it too.** Sparkle's `generate_keys` and `sign_update` are ad-hoc signed as well. `sign_update` blocked on the same prompt when reading the key that `generate_keys` had stored (experiment 4).
- **A killed client leaves its prompt behind.** SecurityAgent ignores SIGTERM. The scripts now kill only SecurityAgent instances spawned during their own run.

**Consequence for B6 ("Remember in Keychain")**
- **The prompt itself.** After every update, the first use of each remembered password shows "Lectern wants to use your confidential information stored in … in your keychain". "Always Allow" adds the new CDHash, until the next update.
- **Unattended paths.** In session restore, or anywhere Lectern can't prompt, the read fails with `errSecAuthFailed` or `errSecInteractionNotAllowed`.
- **What the code must do.** Treat those statuses (and `errSecUserCanceled`) as "no saved password" and fall back to the password prompt.
- **What users must be told.** The prompt is a known limitation of unsigned builds.
- **Workarounds rejected.** Every alternative weakens security (a file in the container) or requires a Developer ID.

## 4. Sparkle 2 with an ad-hoc, sandboxed app

**Result: works end to end, but only with one extra hardened-runtime exception beyond what Sparkle documents.** v1 found, downloaded, validated, installed and relaunched into v2. This worked both in a home folder and in `/Applications`, with no dialog.

**What the documentation says**
- **Sandboxing** (sparkle-project.org/documentation/sandboxing):
  - Sandboxed apps need `SUEnableInstallerLauncherService = YES`.
  - They also need `com.apple.security.temporary-exception.mach-lookup.global-name` for `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki`.
  - `SUEnableDownloaderService` is only for apps without `network.client`, so Lectern doesn't need it.
  - Sparkle's XPC services and helpers ship "signed with an ad-hoc signature and Hardened Runtime enabled". "Code Sign on Copy" re-signs `Sparkle.framework` but not the services inside it.
- **Library validation** (sparkle-project.org/documentation): with only an ad-hoc signature, "the system may not let your application load Sparkle" because of Library Validation. This "is not an issue … with a Developer ID certificate".
- **Update validation** (`SUUpdateValidator.m`, read from the 2.10.1 source):
  - An app bundle update passes if **either** the EdDSA signature verifies against the *old* app's `SUPublicEDKey`, **or** the new app's code signature satisfies the old app's.
  - An ad-hoc app always fails the code-signing branch (the DR is a CDHash), so the EdDSA signature is what authenticates every update.
  - Losing the EdDSA private key means existing installs can never be updated by Sparkle again.

**What happened** (`scripts/04-sparkle.sh`, `results/04-sparkle.txt`, `04b-sparkle-in-Applications.txt`, `sp-*.json`, `logs-sp-*.txt`)
1. **Library Validation killed the first build at launch.** With exactly the documented setup, v1 died in dyld before `main`:

   > Library Validation failed: Rejecting '…/Sparkle.framework/Versions/B/Sparkle' (Team ID: none, platform: no) … reason: mapping process and mapped file (non-platform) have different Team IDs

   `results/logs-sp-0-library-validation.txt` has the full line. An ad-hoc process can't load any ad-hoc framework under the hardened runtime, so this applies to every dynamic framework, not only Sparkle.
2. **Fix.** Add `com.apple.security.cs.disable-library-validation` to the Sparkle variant. No other change was needed.
3. **The update.** The appcast and a `ditto`-zipped v2, signed by `sign_update`, were served from `python3 -m http.server` on 127.0.0.1. ATS allowed the plain-HTTP localhost feed through `NSAllowsLocalNetworking`.
   - **Driver steps.** A headless `SPUUserDriver` answered "install" to every step. It logged: update found (version 2) → download (1,040,180 bytes) → extract → ready to install → `willInstallUpdate` → `willRelaunchApplication` → installing.
   - **The relaunched app.** It was v2 (`bundleVersion 2`), still sandboxed, at the original path, using the same container.
   - **On disk.** `CFBundleVersion 2`, and the CDHash equals the v2 build's. The signature is valid, and there is **no `com.apple.quarantine`**, so Gatekeeper never re-checks a Sparkle-installed update.
   - **Dialogs.** None appeared, and there was no App Management prompt, in either `~/PlatformProbeFixtures/Applications` or `/Applications`.
   - **Not borrowed from this session.** TCC credits the probe and `org.sparkle-project.Sparkle.Updater` to themselves. During the `/Applications` update, the only `kTCCServiceSystemPolicyAppBundles` (App Management) request was about an unrelated app, Raycast (`results/logs-tcc-attribution.txt`).
   - **Which run each file comes from.** `results/04-sparkle.txt` is the home-folder run, and `results/04b-sparkle-in-Applications.txt` is the `/Applications` run. The per-run files `sp-1-update-v1.json`, `sp-2-relaunched.json` and `logs-sp-1-update-v1.txt` were overwritten by the `/Applications` run.
4. **Key handling.** `sign_update` hung on a Keychain prompt for the key `generate_keys` stored (experiment 3). Exporting the key once with `generate_keys -x` and signing with `sign_update --ed-key-file` avoids that. In CI, the key would be a secret file.

**Not verified**
- Updating an app the user launched while it was still quarantined or translocated.
- A real HTTPS host.
- The pre-update permission prompt UI. The probe used a headless driver; Lectern would use `SPUStandardUserDriver`, which is untested here.

**Consequence**
- **What Sparkle adds.** One temporary-exception entitlement, plus disabling library validation for as long as Lectern is ad-hoc signed. Remove that exception the day a Developer ID exists.
- **What it removes.** The quarantine and Gatekeeper ritual on every update.

## 5. Gatekeeper for downloaded unsigned apps

**Result: a downloaded ad-hoc app is blocked with no Open button.** Removing the quarantine attribute (directly, or in a cask's postflight) or building from source works. The System Settings "Open Anyway" route exists but wasn't clicked.

**Evidence** (`scripts/05-gatekeeper.sh`, `results/05-gatekeeper.txt`, `results/gk-*.json`, `logs-gk-*.txt`)

| Check | Result |
|---|---|
| DMG with `com.apple.quarantine` `0083;…;Safari;…` | `spctl --assess --type open --context context:primary-signature`: **rejected**, "no usable signature" |
| App inside the mounted image | `xattr` shows no quarantine on the mounted copy |
| App after `ditto` out of the mount | **quarantined** (`0283;00000000;;<same UUID>`) |
| `spctl --assess -vv` on the app | **rejected**, for every copy including local builds. That's expected for ad-hoc code, and irrelevant once quarantine is gone |
| `syspolicy_check distribution` | Fatal: "Notary Ticket Missing". Warning: "Adhoc Signed App … not suitable for distribution" |

**Routes**

| Route | Result |
|---|---|
| **0. Open the quarantined app** | **Blocked.** The process is held at a translocated path (`/private/var/folders/…/AppTranslocation/…`), and syspolicyd logs "Prompt shown (6, 0), waiting for response". The alert reads "Apple could not verify "PlatformProbe.app" is free of malware…" and offers **Move to Trash** and **Done**, with **no Open button**. While the alert is pending, later launches of the same app are held too. Twice the copy was moved to the Trash from the alert. |
| **a. System Settings → Privacy & Security → Open Anyway** | Documented, not clicked. Apple's steps: after a blocked open, go to System Settings → Privacy & Security → Security, click **Open Anyway** (shown for about an hour after the attempt), enter the login password, click Open. **Control-click → Open no longer works:** "In macOS Sequoia, users will no longer be able to Control-click to override Gatekeeper…" (Apple Developer News, 2024-08-06). Nothing on macOS 26 contradicts this. |
| **b. `xattr -dr com.apple.quarantine`** | **Runs**, sandboxed, no dialog. Works on a fresh copy and on a copy that was blocked first, once that alert was gone. |
| **c. Homebrew cask, plain** (local tap, `file://` DMG, `--appdir` test folder) | Homebrew sets quarantine (`0381;…`), so it's **blocked** like route 0. **brew 7 has no `--no-quarantine` flag.** |
| **c. Cask with legacy `postflight` that runs `xattr -dr`** | **Runs.** brew warns "Calling `postflight` is deprecated! Use `postflight_steps`". |
| **c. Cask with `postflight_steps { run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Lectern.app"] }`** | **Runs**, no warning. This is the form to use. |
| **d. Build from source** | **Runs.** A local build has no quarantine attribute (only `com.apple.provenance`). |

**Homebrew policy** (from brew 7.0.11's own docs)
- **The official tap is closed to Lectern.**
  - `homebrew/cask` requires apps to "pass Homebrew's Gatekeeper checks and must not require System Integrity Protection or Gatekeeper to be disabled or bypassed" (Acceptable-Casks).
  - Casks that fail are deprecated, then disabled, then removed (Deprecating-Disabling-and-Removing; Homebrew-Security-and-Supply-Chain).
  - So an ad-hoc Lectern can only live in our own tap.
- **Our tap needs explicit trust.** Since Homebrew 6.0, non-official taps require explicit trust (Tap-Trust.md). Installing by the fully qualified name printed "Trusted cask ronimoe/lectern-probe/platform-probe". That was a locally created tap; whether a GitHub-hosted tap needs a separate `brew trust --cask …` wasn't verified.
- **Flight blocks.** Legacy Ruby flight blocks are "available temporarily for third-party tap compatibility". Structured `postflight_steps` is the supported form.

**Consequence**
- B5's "notarised DMG" isn't possible. Every first install needs one deliberate bypass: Open Anyway, `xattr`, or the tap's postflight.
- After that, Sparkle updates arrive unquarantined (experiment 4), and `brew upgrade` repeats the postflight.

## 6. CI images

**Result: no GitHub-hosted image has macOS 26 and Xcode 27 together.** Checked 2026-10-29 with `scripts/06-ci-images.sh` (`results/06-ci-images.txt`).

| Label | OS | Xcode |
|---|---|---|
| `macos-26` / `macos-latest` (arm64) | macOS 26.6.2 (25G83), image 20261013 | 26.0.1 … **26.6** (default). No Xcode 27 |
| `xcode-27` / `xcode-27-xlarge` (**public preview**, since 2026-07-16) | **macOS 27.0.1** (since 2026-09-16), image 20261022 | 27.0, **27.1 (27A9275, default, same build as this Mac)**, 27.2 RC |

**Consequence (resolves the §8 [verify])**
- **Build and test with Xcode 27.1.** Use `runs-on: xcode-27` with `/Applications/Xcode_27.1.app`. Tests then run on macOS 27; the macOS 26 deployment target is fine.
- **Preview risks.** The image is marked preview, which means possible queueing and instability.
- **Running on macOS 26 needs a different runner.** That takes a self-hosted runner, or `macos-26` with Xcode 26.6 if the project builds with it (not checked).

---

## Other findings that affect the main app

- **`get-task-allow` in Release.** The Release ad-hoc build carries `com.apple.security.get-task-allow`, because Xcode injects it when signing "to run locally". Release builds should set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`.
- **No dynamic frameworks without an exception.** Under ad-hoc signing with the hardened runtime, Lectern can't load any embedded dynamic framework, including a dynamic SwiftPM product, without `disable-library-validation`. Keep `LecternKit` products static (the SwiftPM default).
- **Build provenance.** Apps built here carry `com.apple.provenance`, and TCC attributes the shell's launches to the parent app. Neither changed any result above.

## Recommendations

**1. Keep the sandbox on.**
- **No ad-hoc rebuild problem is caused by it.**
  - Bookmarks (A2) and the container (§6 storage) survive re-signing silently, in both directions.
  - The one thing that breaks across rebuilds, the Keychain, breaks identically with the sandbox off. It comes from ad-hoc signing (`cdhash:` partitions), not the sandbox.
- **It still delivers what §6 wanted.** Hostile-PDF containment, for the price of entitlements Lectern already has.
- **The only sandbox-specific cost is Sparkle's** `mach-lookup` temporary exception (see 2).

**2. Keep Sparkle, opt-in as A4 says, with two additions.**
- **Additions.**
  - `com.apple.security.cs.disable-library-validation`, for as long as Lectern is ad-hoc signed. Without it the app doesn't launch.
  - The EdDSA private key, kept as a CI secret file and backed up offline. It is the only thing authenticating updates.
- **Why not a "check GitHub Releases" link.**
  - A link means every update is a fresh quarantined download, so the user must repeat the Gatekeeper bypass on every release.
  - A Sparkle-installed update arrives unquarantined, in place, with the container intact.
  - The cost is one weakened hardened-runtime check in an otherwise sandboxed process.
- **Fallback.** If that cost is judged too high, the link is the fallback. Either way, set `auto_updates true` in the cask so `brew upgrade` and Sparkle don't fight.

**3. Treat B6's Keychain storage as a known limitation.**
- Keep "Remember in Keychain" (it's off by default).
- Handle a failed read as "not saved".
- Document the per-update prompt.

**4. Install instructions for users** (replacing B5's notarised-DMG assumption):

> **Homebrew (recommended)**
> ```sh
> brew tap ronimoe/lectern
> brew install --cask ronimoe/lectern/lectern
> ```
> Lectern isn't signed with an Apple Developer ID. Our cask removes macOS's download quarantine after installing, which Homebrew's own `homebrew/cask` doesn't allow; that's why Lectern lives in its own tap. If Homebrew says the tap isn't trusted, run `brew trust --cask ronimoe/lectern/lectern` first.
>
> **Download (DMG)**
> 1. Download `Lectern-x.y.z.dmg` from GitHub Releases, open it, and drag **Lectern** to **Applications**.
> 2. Open Lectern. macOS says it "could not verify Lectern is free of malware". Click **Done**, not Move to Trash.
> 3. Open **System Settings → Privacy & Security**. Under **Security**, click **Open Anyway** next to the Lectern message. This appears for about an hour after step 2. Enter your login password, then click **Open**.
>    *Or, in Terminal, instead of steps 2–3:* `xattr -dr com.apple.quarantine /Applications/Lectern.app`
>
> Right-click → Open no longer bypasses this on macOS 15 and later. You only do this once: updates installed by Lectern's updater don't need it again.
>
> **Build from source** (needs Xcode 27 and XcodeGen. The `xcodegen` and `xcodebuild` lines were run on `m0-skeleton` here and produced an ad-hoc, hardened-runtime `Lectern.app` with no quarantine. The clone only gives a usable app once the app is merged to `main`.)
> ```sh
> git clone https://github.com/ronimoe/pdf-reader && cd pdf-reader
> brew install xcodegen && xcodegen generate
> xcodebuild -project Lectern.xcodeproj -scheme Lectern -configuration Release -derivedDataPath build build
> cp -R build/Build/Products/Release/Lectern.app /Applications/
> ```

**5. Doc updates needed** (not made here; this branch owns only the spike files)
- **architecture.md §8 Release.** Drop Developer ID and notarisation, add EdDSA signing, and the cask with `postflight_steps`.
- **architecture.md §7 and §6.** Add the Sparkle entitlements.
- **architecture.md §8 CI.** Point it at `xcode-27`.
- **decisions.md B5.** "Notarised" no longer applies.
- **decisions.md B6.** Add the per-update Keychain prompt.

## Not verified

- **The "Open Anyway" flow.** Never clicked, by instruction. The steps come from Apple's support page.
- **Sparkle's standard UI path, and updates over HTTPS from GitHub Releases.** Untested; the headless driver and a localhost feed were used.
- **Updating a copy that is still quarantined or translocated.** Not tested.
- **Sparkle's scheduled background path.** The update was triggered with `checkForUpdates()` and an auto-accepting driver. `SUAutomaticallyUpdate` (silent download, install on quit) wasn't exercised.
- **Hosting.** The Homebrew tap `ronimoe/homebrew-lectern` and the GitHub Releases DMG don't exist yet, so those install commands are templates.
- **`brew trust` behaviour for a GitHub-hosted tap.** Not tested.
- **Whether Lectern builds with Xcode 26.6** (the `macos-26` image). Not checked.
- **Behaviour on other macOS 26.x or on macOS 27.** Only macOS 26.6.2 was tested.

## Cleanup state

`scripts/cleanup.sh` has been run.
- **Removed.**
  - Probe processes are killed and the appcast server is stopped.
  - All test Keychain items are gone. Each was deleted by the build that created it, so no prompt appeared.
  - No DMG is mounted, and the test tap and casks are gone.
  - `/Applications/PlatformProbeSparkle.app` and `~/PlatformProbeFixtures` are removed.
  - LaunchServices registrations are removed, as is the probe containers' `Data/`.
- **Left in place.**
  - **The container roots.** `~/Library/Containers/io.github.ronimoe.PlatformProbe{,Sparkle}` remain, each holding only its protected metadata plist. Remove them in Finder if wanted.
  - **The Sparkle test key.** A login-Keychain generic password (account `lectern-m0c-probe`, service `https://sparkle-project.org`) remains, because deleting it from the shell would prompt. Delete it in Keychain Access.
- **A side effect.** One `brew uninstall` during the spike autoremoved the orphaned formula `libngtcp2`, which nothing depended on. The scripts now set `HOMEBREW_NO_AUTOREMOVE=1`.
