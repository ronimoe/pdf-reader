# Release acceptance audit (spec §11)

Each criterion in [product-spec.md](product-spec.md) §11, as of M6 (2026-10-30), updated for M7 (encrypted files, 2026-10-30). Status is one of:

- **Met**: done and checked automatically.
- **Met, with caveats**: done, but part of it can only be checked by hand or on other hardware; the caveat says which.
- **Your action**: needs a decision or an action from the maintainer.

The evidence names test suites (`AppTests/…` run in the app by `scripts/test.sh`; package suites in `Packages/LecternKit/Tests/`), documents, and milestone entries in [progress.md](progress.md). Every "Met" rests on the automated suites, which drive the app in-process and headlessly: no test has looked at the app on a real screen (the user declined screen access), so on-screen look and real input devices are caveats throughout.

**Summary:** of 21 criteria, 8 are met, 12 are met with caveats, and 1 is your action (making the project public). The caveats are the manual checks in [release-checklist.md](release-checklist.md) §5, and above all performance on the A6 baseline Mac.

## Core functionality

| Criterion | Status | Evidence | Caveats |
|---|---|---|---|
| Supported ordinary PDF files open and display reliably | **Met** | `RegressionSuiteTests` opens every file in the collection (37, including a 3,270-page manual, a 200-page image report, a scan, signed, certified, encrypted (R2 to R6, a public-key file), linearized, hybrid and Reader-extended files), renders page 1 and checks text; `LifecycleTests`, `ReaderDocumentTests`; the M5 snapshot review (light and dark) | — |
| Essential reading modes work correctly | **Met, with caveats** | `ReaderWindowLayoutTests`, `ReaderWindowZoomTests`, `ViewSettingsTests`, `DocumentLayoutHintsTests` (B1: single/two-up, continuous/paged, cover page, right-to-left; fit modes; rotation B9); `KeepingYourPlaceTests` | Checked offscreen; the on-screen look only through offscreen snapshots |
| Navigation and search are dependable | **Met** | `NavigationTests`, `HistoryStackTests`, `GoToPageTests`, `SidebarTests`, `SearchTests`, `SearchTextTests`; on the 3,270-page manual the first result reaches the list after 0.46 s and the main thread is never busy more than 57 ms ([performance.md](performance.md)); the update coalescing now also works inside nested run loops (`ReleaseTests.resultsReachTheListWhileALongSearchRuns`) | — |
| The reference preview works for supported internal links | **Met, with caveats** | `LinkPreview`, `LinkRouting` and `SplitView.RealPaper` (an arXiv paper with 420 internal links); hover, Force Click and keyboard paths driven with synthesized events (M3) | Real trackpad hover and physical Force Click not tried by hand (M0b, M3) |
| Basic annotations can be created, modified, and saved safely | **Met, with caveats** | `EditTests`, `UndoRedo`, `SavingTests.EndToEnd`, `CopyOnly`, `CrashJournal`, `ChangedOnDisk`; package `CorpusTests` (pass criteria of architecture §3.2 on every file, checked by qpdf, MuPDF, Poppler, pdf.js and pyHanko); M6 adds the GovInfo-certified book and the 3,270-page manual. M7: password-encrypted files (RC4, AES-128, AES-256) in `EncryptedSavingTests` and `EncryptionTests`, with the strong oracle (`CorpusTests.encryptedOutputsMatchTheirPlaintextTwins`: the same edits on a decrypted twin give identical annotations once qpdf decrypts the output) and qpdf's own file key | Preview and Acrobat Reader by hand, including an encrypted file; an in-place save, under the sandbox, of a file chosen from the user's own folders (M4b); a document with a non-ASCII password can't be opened at all (PDFKit, [known-limitations.md](known-limitations.md)) |
| Reading position restoration functions reliably | **Met, with caveats** | `StoredStateTests`, `DocumentStateStoreTests`, `DocumentMatcherTests`, `KeepingYourPlaceTests`, `SessionRestoreTests` | Session restore across a real quit and relaunch, with files outside the container (M5) |

## Experience

| Criterion | Status | Evidence | Caveats |
|---|---|---|---|
| First-time users can accomplish basic reading tasks without instructions | **Met, with caveats** | Standard macOS document app: Open in the empty state, File ▸ Open Recent, drag and drop, menus with standard shortcuts; `EmptyStateTests`, `MainMenuTests`; README "Getting started" | No usability test with first-time users has been done; that's a judgement for you |
| The interface remains uncluttered | **Met, with caveats** | Spec §4 layout as built: toolbar, collapsible sidebar, distraction-free mode; M5 snapshot review in `build/snapshots/` (light and dark) | Judged from offscreen snapshots, not on a screen |
| Common actions are discoverable | **Met** | Every toolbar action has a menu equivalent (`AccessibilityAudit` fails otherwise); Help ▸ Keyboard Shortcuts is generated from the live menu (`KeyboardShortcutMapTests`); context menus (`ReaderContextMenuTests`) | — |
| Keyboard accessibility works for essential controls | **Met, with caveats** | `AccessibilityTests` / `AccessibilityAudit`: no unnamed or keyboard-unreachable control in the reader window, toolbar, popovers and SwiftUI screens; link focus (⌥⇥); Reduce Motion | VoiceOver end to end; keyboard focus inside SwiftUI controls; the form Tab guard with a real keyboard |
| Light and dark appearances are visually consistent | **Met, with caveats** | `SnapshotTests` (fails on a dark capture that is mostly white) and the M5 coordinator review of light and dark renders | Offscreen renders approximate glass and toolbars (architecture §9) |

## Reliability

| Criterion | Status | Evidence | Caveats |
|---|---|---|---|
| Representative documents have been tested | **Met, with caveats** | M6 corpus: text-heavy book, 3,270-page manual, image-heavy report, scan ([Tests/Corpus/README.md](../Tests/Corpus/README.md)); `RegressionSuiteTests`, `CorpusTests`, `MatchingCorpusTests`; `RepresentativePerformanceTests` via `scripts/perf.sh` (37 measurements, all within threshold) | Thresholds are provisional: measured on an M3 Pro; the A6 baseline (base M1, 8 GB) wasn't available ([performance.md](performance.md)) |
| Supported annotation content survives saving and reopening | **Met, with caveats** | `CorpusTests.pdfKitShowsAnnotations`, `pdfKitDrawsMarkup`, the external readers in `scripts/corpus/verify`; `SavingTests.EndToEnd`; `MatchingCorpusTests` (every annotation matched after the save) | Preview and Acrobat Reader by hand |
| Original document content is not silently corrupted or discarded | **Met** | `CorpusTests.originalBytesArePrefix`, `untouchedObjectsUnchanged`, `formFieldsUnchanged`, `signatureStillIntact`, `qpdfCheckPasses`; `SavedFileCheckTests` (read-back before the swap, comparing decrypted text, not counts: `EncryptionTests.aWrongObjectKeyIsCaught`), and a second read-back through PDFKit (`EncryptedSavingTests.thePDFKitReadBackCanFail`); `CrashJournal`, and the sealed journal of encrypted files (`EncryptedJournalTests`); `encryptedOutputsKeepTheirEncryption` (no re-encryption, `/Encrypt` and `/ID` unchanged); autosave off, so reading never writes (`ReaderDocumentTests`, A1) | — |
| Invalid or unsupported PDFs are handled safely | **Met** | `MalformedInputTests`, the seeded fuzz tests (`RobustnessTests`, including 3,000 mutations of the encrypted files and their encryption dictionaries), `EncryptionTests.malformedEncryptionIsRefusedWithoutTrapping`, `SavingTests.Unsupported`, `ReaderWindowPasswordTests`, `ReaderWindowPermissionTests`; blocked actions (`LinkRouting`, `Q1JavaScript`, `Q2Actions`) | — |
| No known release-blocking crashes remain in normal reading workflows | **Met, with caveats** | The PDFKit background-queue crash was fixed and is guarded by `PDFKitBackgroundQueueTests` (hotfix entry in progress.md); no crash report from `verify-dmg`'s self-check; `scripts/test.sh` passes twice in a row | No field use yet; the built app has only been run headlessly in M6 |

## Project principles

| Criterion | Status | Evidence | Caveats |
|---|---|---|---|
| The application is publicly available as open-source software | **Met** | GPL-3.0 (`LICENSE`, in the app and on the DMG); the repository is public, and the [v1.0.0 release](https://github.com/ronimoe/pdf-reader/releases/tag/v1.0.0) has the DMG, its checksum, the update archive and the appcast, all downloadable without signing in (checked 2026-10-31) | The Homebrew tap `ronimoe/homebrew-lectern` is created by the maintainer (checklist §4) |
| Core use does not require registration or online access | **Met** | No accounts anywhere; Sparkle is created only after opting in or Check Now (`UpdateTests`); the network entitlement is for updates only; the About panel and Settings say so | — |
| There are no ads, subscriptions, or AI features | **Met** | Nothing of the kind in the app; PDFKit's own Vision-based page analysis is switched off (`PDFKitBackgroundQueueTests`); `PrivacyTests` (no hidden metadata written) | — |
| Installation and basic usage are documented | **Met, with caveats** | [INSTALL.md](INSTALL.md) (Homebrew, DMG with Open Anyway and the `xattr` alternative, build from source, updating, uninstalling, the Keychain question); README "Getting started"; Help ▸ Keyboard Shortcuts | The DMG route's Open Anyway steps follow Apple's documented flow and haven't been walked through on macOS 26 |
| Known limitations are clearly communicated | **Met** | [known-limitations.md](known-limitations.md), linked from the README and shown in the app under Help ▸ Known Limitations (`ReleaseTests.theLicenceNoticesAndLimitationsShipInTheApp`) | — |
