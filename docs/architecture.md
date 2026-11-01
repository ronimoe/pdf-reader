# Architecture

This document answers the technical questions that [product-spec.md](product-spec.md) §13 leaves open. It works within the product decisions in [decisions.md](decisions.md), referred to by ID (A1–A6, B1–B9).

**Status:** Draft, 2026-10-29. One decision is still open: **how annotations are saved (§3.2)**. It waits on the Milestone 0 prototypes (§11). Any statement here about how PDFKit behaves is an assumption until those prototypes confirm it. Such statements are marked **[verify]**.

---

## 1. Language

**Swift 6, with the compiler's strict concurrency checking switched on.** Development uses the Swift 6.4 toolchain that ships with Xcode 27.

- **Why:** Swift is the native language for AppKit, SwiftUI and PDFKit. Strict concurrency catches threading mistakes at compile time, which matters because PDFKit objects are not safe to use from several threads at once.
- **Rules out:** cross-platform languages and runtimes (Rule 9), and a C++ core.

## 2. UI toolkit

**AppKit provides the app shell, and SwiftUI is used for self-contained views.**

**AppKit is used for:**
- **The document class.** An `NSDocument` subclass handles opening, recent files, file coordination and Save a Copy.
- **Windows.** An `NSWindowController` per window, with native window tabs.
- **The split view.** An `NSSplitViewController`.
- **The reading surface.** A subclass of PDFKit's `PDFView`.

**SwiftUI is used for (hosted in AppKit):**
- the sidebar sections,
- the link-preview popover chrome,
- the search results,
- Settings,
- the empty state,
- the password prompt.

**The sidebar's lists are AppKit** *(Amended 2026-10-29, M2)*
- The outline, thumbnails and search results are `NSOutlineView` and `NSTableView`, not SwiftUI lists. The section picker and its container are AppKit too (`SidebarViewController` in ReaderUI).
- **Why:** a click and Return must jump and add one history entry, while the arrow keys only move the selection. A SwiftUI `List` can't tell a keyboard selection change from a click. Table rows are also created lazily, which is what lazy thumbnails need, and tables can be driven in tests without rendering.
- Go to Page is a SwiftUI sheet, like the password prompt.
- **Adding a section (M4, M5):** add a `SidebarSection` case and a `SidebarSectionViewController` subclass.

**The empty state and untitled documents** *(Amended 2026-10-29, M1)*
- A reader has no untitled documents. `ReaderDocumentController`, an `NSDocumentController` subclass, refuses to make one, and New opens the Open panel instead.
- The subclass must be created in `main.swift` before `NSApplicationMain`, because the first instance becomes `.shared`.
- AppKit asks for an untitled document at launch when nothing was opened or restored, and on a Dock click with no windows. `applicationOpenUntitledFile` answers both by showing the empty-state window.
- The document controller reports every add and remove, one run-loop turn later. The empty state is shown whenever the count reaches zero and hidden otherwise.

**Settings, the shortcut map and the bookmarks list** *(Amended 2026-10-29, M5)*
- **Settings** (⌘,) is `SettingsView` (ReaderUI, SwiftUI) in an AppKit window owned by `SettingsWindowController`. Each control writes its preference at once; there is no Apply. Hover previews share one preference with the View menu.
- **Help ▸ Keyboard Shortcuts** (⌘/) is a SwiftUI list built from the running `NSApp.mainMenu` every time it opens (`KeyboardShortcutCatalog`), so it can't drift from the menus. Visible items with a key equivalent are listed; hidden alternates (⌘= for Zoom In, AppKit's spare ⌃⌘F) work but aren't.
- **Bookmarks** are a sidebar section (`BookmarksSectionViewController`, AppKit like the others), between the table of contents and the annotations.

**Why not SwiftUI throughout?** SwiftUI's document architecture (`DocumentGroup`) doesn't give enough control over four things this app depends on:
- saving (A1),
- reacting when the file changes on disk (B7),
- tab and window behaviour (B3),
- the reading surface, which is AppKit-only.

**Turning off autosave (A1).** Override `autosavesInPlace` to return `false`, and turn off autosave-as-you-go and Versions. A save happens only through an explicit Save. The crash journal (§5.4) does the job autosave would otherwise do.

## 3. PDF engine

### 3.1 Rendering, text, search and annotation model: PDFKit

PDFKit (system framework) is used for rendering, text extraction and selection, search, the outline, link annotations, and the in-memory model of annotations.

**Why PDFKit**
- It's built into macOS, so it adds no binary to ship.
- It supports VoiceOver for PDF content.
- It behaves like Preview, which suits the macOS-first rule.
- It's maintained by Apple.

**Known risks, each checked in Milestone 0 [verify]**
- **Saving** rewrites the whole file instead of appending changes. This is the reason §3.2 exists.
- **JavaScript.** Whether PDFKit ever executes a document's JavaScript.
- **Interactive actions.** How `Launch`, `GoToR` (links to other files) and form-submit actions are exposed, and whether the app can stop them from running.
- **Form fields.** Whether they can be made non-editable without changing the document model (see §4.3).
- **Thread safety.** Whether thumbnails can be generated on a background thread with a second `PDFDocument` instance, and how fast that is.
  - *(Measured 2026-10-29, M2, macOS 26.)* Yes. A second `PDFDocument` built from the same bytes on a background thread drew 100 thumbnails in 70 ms while the main thread drew from its own document at the same time.
- **Search.** Whether `beginFindString` returns results progressively (B8) without blocking the main thread.
  - *(Measured 2026-10-29, M2, macOS 26.)* Yes. It returns in microseconds. Matches arrive on the main thread, page by page, through `PDFDocumentDidFindMatch` and the delegate. On a 600-page document the run loop kept turning, with the longest gap about 20 ms, and the whole search took 1.2 s against 0.02 s for the blocking `findString`.
  - `cancelFindString` stops the callbacks at once. `.diacriticInsensitive` works. There is no whole-word option, so Whole Word filters the matches.
  - The M0b spike branch had published nothing when M2 started, so these numbers come from M2's own probe.

### 3.2 Saving annotations: **decided: candidate 1, our own incremental writer** *(Amended 2026-10-29)*

The M0a prototype passed every applicable pass criterion on the whole generated test collection. Full results are in [spikes/m0a-save.md](spikes/m0a-save.md). Encrypted files were refused with `PDFSaveError.encrypted`. *(Amended 2026-10-30, M7: the writer now saves into files encrypted with the Standard security handler; see item 7 below and §4.3.)*

*(Amended 2026-10-29, M4a.)* `Saveability.evaluate` reports one of three outcomes:
- `inPlace`,
- `copyOnly`, for signed, certified (DocMDP) and Reader-extended (UR3) files, and files in a read-only location,
- `unsupported`, for malformed files and, since M7, only the encryption the writer doesn't handle (`UnsupportedReason.encrypted(EncryptionProblem)`: revision 5, a non-Standard handler, a custom crypt filter, or a password it can't authenticate). Supported encrypted files are `inPlace` or `copyOnly` like any other.

Copy-only files are saved with `saveCopy`, which is the original bytes plus the appended update, written to a new file. The production API is described in [spikes/m4a-save-engine.md](spikes/m4a-save-engine.md).

**Open work for production (M4)**
- Map each `PDFAnnotation` to its object in the file. Our own annotations are matched by `/NM`; third-party ones by page and `/Rect`.
- Fuzz the parser.
- Test the writer on real-world files: linearized, certified (DocMDP) and Reader-extended (`/Perms /UR3`).

*(Amended 2026-10-29, M4b.)* The open work above is done (M4a), except checking Preview and Acrobat Reader by hand. How the app uses the writer:
- **What gets saved.** `ReaderDocument` keeps an ordered `PendingChanges` list (PDFSave). Every user action appends to it, or folds into the pending add of an annotation that was never saved, and makes the same change to the PDFKit model for display. The list is never derived by comparing PDFKit with the file.
- **Matching.** Before anything on a page changes, all of that page's PDFKit annotations are matched in one `AnnotationMatcher` batch against the descriptors read at open (or at the last save). Annotations added since the last save are left out. Anything but `.matched` is refused with an explanation.
- **Which writer.** ⌘S on an `inPlace` file runs `saveInPlace` through `NSDocument`'s safe save. Save As (and B7's Save a Copy) runs `saveCopy`. A `copyOnly` file, or one deleted since it opened, sends ⌘S to a Save As panel whose message gives the reason. An `unsupported` file refuses annotations when they're made, so it never has anything to save; ⌘S explains why instead of doing nothing.
- **Never over a protected original** *(Amended 2026-10-29, M4b review)*. Save As, Save To and B7's Save a Copy refuse a destination that is the document's own file, compared by `.fileResourceIdentifierKey` after resolving symbolic links (so a symlink, another path or a hard link to it counts), unless the document is `inPlace` and its file is still `originalData`. The check runs when the save starts and again in `write(to:…)`, just before the bytes are written. The copy route's panel suggests "<name> (annotated).pdf".
- **NSDocument always gets an answer** *(Amended 2026-10-29, M4b review)*. When ⌘S is refused or goes to the changed-on-disk question, a caller's `didSave` callback still fires with `false`, so Close ▸ Save and Quit ▸ Save don't wait forever. Save errors go through the window's presenter, except that a cancellation shows nothing (and still answers) and an error with a recovery attempter goes to AppKit's own alert.
- **A touched file isn't a changed file** *(Amended 2026-10-29, M4b review)*. When the bytes on disk still equal `originalData` but the modification date moved, ⌘S takes the new date as the document's, so `NSDocument` doesn't ask "changed by another application" over B7's head.
- **The check after writing.** `write(to:ofType:for:originalContentsURL:)` writes the bytes to NSDocument's temporary file, reads them back, and runs `SavedFileCheck`: the bytes are the writer's, the original is a prefix, and the annotation count is the original's plus the added ones minus the removed ones, with every added `/NM` on its object. A failure throws before the swap, so the original stays intact.
- **After a save.** The written bytes become `originalData`. The list empties, descriptors and matching restart from the new bytes, and `Saveability` is re-checked in the background. The pages aren't reloaded and the reader's place stays.
- **Never on changed bytes.** ⌘S compares the file on disk with `originalData` first and goes to the B7 choice if they differ; the write path checks again.

The candidate table and pass criteria below are kept as the record of how the decision was made.

The save path must:
- **append** changes to the original file (an incremental update), and
- **leave the original bytes untouched.**

The candidates, in order of preference:

| # | Candidate | License | Notes |
|---|-----------|---------|-------|
| 1 | **Our own incremental writer in Swift** | GPL-3.0 (ours) | Parse just enough of the original file (cross-reference tables or streams, the trailer, and the page and annotation objects involved, including ones packed inside compressed object streams). Then append the new or changed annotation objects, the changed pages' annotation lists, a new cross-reference section, and a trailer pointing back to the previous one. No added dependency, and we control exactly what gets written. Cost: a small, well-tested parser for PDF's internal object structure. |
| 2 | **PDFium (Google's PDF engine), used only for saving** | BSD-3-Clause, compatible with GPL-3.0 | It has a built-in incremental save. Cost: a large C++ binary to ship, a second in-memory model of the document, and translating annotations between PDFKit and PDFium. |
| 3 | **MuPDF, used only for saving** | AGPL-3.0, which GPL-3.0 §13 allows combining with | Also supports incremental saves. Same costs as PDFium, plus stricter AGPL terms that apply to the combined app. Only if 1 and 2 both fail. |

**Pass criteria.** Each candidate is tested against the whole test PDF collection. It must meet all of these:

1. **Original bytes intact.** The original file's bytes are an exact prefix of the saved file.
2. **Independent structural check.** `qpdf --check` accepts the output. Reopening it in PDFKit doesn't count, because it would be checking its own work.
3. **Annotations round-trip.** Reopening the saved file shows the expected number of annotations, of the right types, and with the right `Contents`.
4. **Form data unchanged (A5).** Every form field's value is byte-identical.
5. **Signatures unchanged.** Signature fields and their signed byte ranges are unchanged. Signed documents still go to Save a Copy for v1 (A1), but the writer must not damage them.
6. **Other readers.** The highlights and notes show up in Preview, Acrobat Reader and pdf.js (journey C, step 6).
7. **Encrypted files: measure and decide.** Find out whether new objects can be encrypted with the document's key (RC4 or AES). If not, encrypted documents are added to the list that always goes to Save a Copy.
   - *(Outcome, 2026-10-30, M7.)* **They can, and they are saved in place.** PDFSave authenticates the password itself and encrypts the update with the file's own key: the Standard handler at R2 and R3 (RC4, 40 to 128 bits), R4 with `/V2`, `/AESV2` or `/Identity` (strings and streams may differ; `/EncryptMetadata false` honoured), and R6 (`/AESV3`). The fixtures cover R2 (40-bit), R3 (56- and 128-bit), R4 with each filter (128-bit), R6, and Apple's own CoreGraphics output (40-bit R3, AES-128 R4, generated in the tests); other key lengths are covered by the same code but no fixture. Each passes criteria 1 to 6 with the password, plus a **strong oracle**: the same edits made on the file's plaintext twin (`qpdf --decrypt` of the fixture) and on the encrypted file give identical annotation objects once qpdf decrypts the output (`scripts/corpus/verify --check oracle`). The derived file key equals qpdf's (`--show-encryption-key`) for the user and the owner password of every fixture. R5, the public-key handler, custom crypt filters and unauthenticated passwords stay `unsupported` (B6, amended 2026-10-30).

**Fallback if every candidate fails.** All saves go through Save a Copy, using PDFKit's normal write on a clean document (§4.3). In-place saving moves out of v1.

## 4. Software architecture

### 4.1 Modules

The app is an Xcode app target plus local Swift packages. Dependencies only point downward.

```
App (AppKit shell)
 ├─ ReaderUI        SwiftUI views (sidebar, preview chrome, search list, settings, empty state)
 ├─ ReaderKit       PDFView subclass, panes, link-hover/focus, anchor capture/restore
 ├─ ReaderCore      pure Swift, no PDFKit: anchors, history, document identity, view settings, policies
 ├─ PDFSave         incremental writer (§3.2), post-save verification, Save a Copy
 └─ Persistence     per-document state files, crash journal, Keychain access
```

- **ReaderCore** and **PDFSave** have no UI. Most unit tests live there.
- *(Amended 2026-10-29, M4b)* **Persistence** depends on **PDFSave** as well as ReaderCore: the crash journal stores `AnnotationChange` values. PDFSave is still a leaf (Foundation and Compression only).
- *(Amended 2026-10-30, M7)* PDFSave also uses Apple's CryptoKit (MD5, SHA-2) and CommonCrypto (AES-CBC and -ECB, RC4) for encrypted files, and Persistence uses CryptoKit's AES-GCM and HKDF for the sealed journal. No new dependency.
- **ReaderKit** is the only module that touches `PDFView`.

### 4.2 How a document is organised at runtime

**One document, one `NSDocument`**
- Each open document is a single `NSDocument`.
- It holds the **bytes as originally loaded** and a **`PDFDocument`** built from those bytes.

**Why keep the original bytes**
- The incremental writer appends to these bytes, never to whatever is on disk at save time.
- B7's Save a Copy also writes these bytes, plus the unsaved annotations, after the file on disk has changed underneath.

**Panes**
- Each tab has one or two panes.
- Each pane is a `ReaderPDFView` with its own `HistoryStack` (B2) and `ReadingAnchor`.
- Both panes share the same `PDFDocument`.
- **Annotation changes don't reach the other pane on their own** *(Amended 2026-10-29, M0b Q7)*. A live annotation change shows only in the pane that last laid out the page. After every annotation change, the other pane must re-assign its `document`, keeping its anchor, to refresh. Five cheaper refresh calls were tried and none worked.

**Focus (B3)**
- The tab tracks which pane is focused.
- The sidebar and search act on that pane.

**Changes on disk (B7)**
- The document watches its file through `NSFilePresenter` (or `NSDocument`'s built-in handling).
- It applies B7's rules: reload silently when there are no unsaved annotations; otherwise ask.

**How M2 builds this** *(Amended 2026-10-29, M2)*
- **Panes.** `ReaderPane` (ReaderKit) pairs a `ReaderPDFView` with a `PaneID` and its `HistoryStack`. Every jump goes through the pane, so each is recorded once. The window has one pane, `.primary`, until M3.
- **Watching the file.** `ReaderDocument` overrides `NSDocument`'s presenter methods rather than relying on its default revert:
  - `presentedItemDidChange` waits 0.3 s for the writer to settle, then reads the file through `NSFileCoordinator`. It reloads only if the bytes differ and parse; a half-written file is skipped until the next change.
  - **Reload.** The bytes, the model, the original rotations, the hints, the labels and the document key are all replaced. The document is unlocked again with the session password, which is kept in memory only. The window keeps the anchor, clamps the history to the new page count, re-runs a running search in the same session, rebuilds the background workers, and shows "Reloaded" for 1.5 s.
  - **Removed.** A deletion, or a move into a `.Trash` folder, keeps the document open with a lasting notice.
  - **Moved or renamed.** `NSDocument` updates `fileURL`, and the stored identity is refreshed.
- **Not done until M4:** the unsaved-annotations question.

**Unsaved annotations when the file changes** *(Amended 2026-10-29, M4b)*
- `reloadFromDiskIfChanged()` doesn't reload a document with unsaved annotations. It asks, once at a time: **Reload** or **Save a Copy**.
- **Reload** asks for confirmation, then reloads the file and drops the unsaved annotations, the journal and the undo history.
- **Save a Copy** asks where, suggesting "<name> (annotated).pdf", writes `saveCopy(originalData, changes)` (the version loaded here plus the annotations) through `NSDocument`'s Save To, and opens the copy. This window then reloads to the file's new version, since the annotations now live in the copy. The changed file is never written: choosing the document's own file as the destination is refused (§3.2), and the annotations stay unsaved here.
- ⌘S on a file whose bytes on disk differ from `originalData` asks the same question instead of saving.
- A clean document still reloads silently, as in M2. Any reload clears the undo history, which refers to the old model.

**Annotation changes in both panes** *(Amended 2026-10-29, M4b)*. After every change, including undo, redo and a journal restore, the window calls `notifyAnnotationsChanged(from:)` with the focused pane. A pane's selected annotation survives the re-bind.

**How M3 builds the split** *(Amended 2026-10-29, M3)*
- **Layout.** The reading area holds a nested, vertical `NSSplitViewController` with one `PaneContainerView` per pane. A container holds the `ReaderPDFView`, a 3 pt focus bar along the top of the focused pane's safe area (shape as well as colour), a close button, and the link status line. A second pane is created at equal width.
- **Focus.** The focused pane follows the window's first responder (KVO). Outline, thumbnails, Go to Page, search, zoom and Back/Forward act on it. A search keeps acting on the pane it started in until it ends.
- **Layout, rotation and reload** apply to every pane inside every pane's anchor capture.
- **Zoom is per pane.** Zoom commands act on the focused pane. Only the first pane writes `ViewSettings.zoom`; the second pane's zoom is stored in `SplitState.secondaryZoom`. The View menu's zoom checkmarks show the focused pane's zoom.
- **Closing.** Either pane can close. Closing the first pane moves the second pane's place, zoom and history into it, so the pane that stays is always `.primary`.
- **Open in Split** from a preview creates the split at the destination with an empty history; focus stays on the reader's pane. If the tab is already split, the other pane jumps there and records it in its own history.
- **Stored state.** `DocumentState.split` (`SplitState`: the second pane's anchor and zoom, and the focused pane) is stored with the second pane's history under `PaneID.secondary`. `anchor` stays the first pane's place. Older state decodes with no split.
- **Assigning a document.** Always through `ReaderPDFView.show(_:)`, never by setting `document`. This follows main's crash fix: PDFKit reads `document` from background queues.
  - The view also re-attaches its clip-view observer on every `layout()` and `restore`, because PDFKit can replace its scroll view after a document change. Without that, a later `layoutDocumentView()` moved the reader by about 25 pt and nothing put them back (found while restoring a split).
- **Content starts below the toolbar.** The scroll area still runs under the toolbar (full-size content view). But `ReaderPDFView` keeps its scroll view's `contentInsets` equal to its safe area, and lets its own scroll clamp reach into them.
  - A document seen for the first time opens at the top of page 1, with the page's top edge just below the toolbar. Before this, the clamp left about 23 pt of page 1 under it.
- **Changes on disk.** The coordinated read in `ReaderDocument.reloadFromDiskIfChanged()` (now `async`) runs on a background queue and applies its result on the main actor. The window no longer freezes while another app holds the file for writing.

### 4.3 Rule: what's on screen must never leak into a saved file

PDFKit's obvious ways to rotate a page, lock a form field or set an annotation's author all change the `PDFDocument` itself. So:

- **Rotation (B9)** is applied with `PDFPage.rotation` in the shared model, because PDFKit offers no separate per-view rotation [verify]. The original value of every page is recorded when the document opens.
  - *(Amended 2026-10-29, M1)* For an encrypted document, "opens" means the moment it is first unlocked, because the pages aren't readable before then. `ReaderDocument.originalPageRotations` and `originalRotation(ofPageAt:)` give the save path these values.
  - The view rotation is applied as `original + ViewSettings.rotation` on every page.
  - Printing uses the on-screen model, so a rotated view prints rotated, as in Preview.
- **Form fields (A5)** stay non-editable because `ReaderPDFView` catches mouse and keyboard events aimed at them. Their `isReadOnly` flag is never set. Prototype check [verify]: whether keyboard focus can still reach a field.
  - *(Amended 2026-10-29, M4b)* A mouse-down on a Widget is swallowed after the link check. While the document has form fields (a non-empty AcroForm `/Fields`, or any Widget annotation on a page, read from CoreGraphics' dictionaries), Tab and Shift-Tab move through the window's key view loop instead of reaching PDFKit.
  - *(Amended 2026-10-29, M4b review)* The click blocking is tested against a positive control: the same click on the same field starts editing in a stock `PDFView`. **The Tab handling can't be tested headlessly.** In a stock `PDFView`, Tab never moves focus into a field (M0b Q3), and with synthesized events PDFKit passes Tab on to the window's key view loop exactly as `ReaderPDFView` does, so a build without the Tab handling passes every test. It stays as a guard for real keyboards, and whether one can Tab into a field stays [verify]. A dismissible line says "This document has form fields. Filling in forms isn't supported yet." VoiceOver activation of widgets is still unchecked (M5).
- **The author (B4)** is set only on new annotations, from Settings, where the default is empty.
  - PDFKit fills in `/T` (the Mac account's full name) and `/M` (a date) on every new annotation, including its popup, on its own *(Amended 2026-10-29, M0b Q5)*.
  - Clear both explicitly, and set them only from Settings. The incremental writer serialises only what we give it, so it is the final guard.
  - *(Amended 2026-10-29, M4b)* Every `PDFAnnotation` the app creates gets `/NM` set to its change's name, `userName` set to the author or nil, and `modificationDate` set to nil, on its popup too. The author comes from the `annotationAuthor` user default, empty by default; Settings arrives in M5.

**What gets written**
- The **incremental writer** writes only the objects the app chose to create or change: annotation objects, plus the annotation lists of the pages involved. Changed rotation therefore can't reach the file.
- **Save a Copy is the original bytes plus the incremental writer's appended section, written to a new file.** PDFKit's own `write(to:)` and `dataRepresentation()` are never used to save *(Amended 2026-10-29, M0b Q6)*. They rewrite the whole file, which:
  - drops page labels, `/ID`, custom metadata and the revision history,
  - separates form fields from their widgets, so `qpdf` warns on every widget, which breaks A5.

  The only case where the incremental writer can't produce the copy is an encrypted document (`PDFSaveError.encrypted`). Saving annotations into encrypted documents isn't supported in v1. The app explains this and saves nothing.

**Encrypted documents** *(Amended 2026-10-30, M7: replaces the paragraph above.)* Annotations are saved into documents encrypted with the Standard security handler (R2, R3, R4, R6), and the file stays encrypted exactly as it was.
- **The key.** PDFKit doesn't expose the file key or which password matched, so `PDFSaveDocument(data:password:)` authenticates on its own (ISO 32000-2 §7.6.4, algorithms 2, 2.A, 2.B, 6, 7 and 11). It tries the session password as the user password, then as the owner password, then the empty user password (files that open without a prompt, for which the app holds no password). Only a key that reproduces `/U` (through `/O` for the owner password), and for R6 also decrypts `/Perms` to the dictionary's `/P` and `/EncryptMetadata`, is ever used; otherwise the file is `unsupported(.encrypted(.passwordNotAuthenticated))`. Passwords are PDFDocEncoding padded to 32 bytes for R2 to R4, and SASLprep'd UTF-8 cut to 127 bytes for R6 (each also tried as its plain UTF-8; only one that authenticates counts). The owner key's 50 MD5 rounds (algorithm 3) hash the first n bytes, as qpdf, PDFKit, Acrobat and PDFBox do; pdf.js hashes all 16, which only differs below 128 bits (the R3 56-bit fixture tells them apart). *(M7 review.)* Malformed `/V`, `/R`, `/Length`, `/O`, `/U`, `/OE`, `/UE`, `/Perms` or `/CF`, an encryption dictionary that repeats a key, and AES data that isn't an IV plus whole blocks throw a typed error, never trap (`EncryptionTests`, and 3,000 fuzzed mutations of the encrypted fixtures).
- **Reading.** The handler is installed before any object is resolved. Each indirect object's strings and streams are decrypted as it is read, with the key of the object number and generation the file gives it; objects inside an object stream are decrypted with their stream, never one by one. Never decrypted: the `/Encrypt` dictionary, a signature dictionary's `/Contents` (`/Type /Sig` or `/DocTimeStamp`, or any dictionary with `/ByteRange`), cross-reference streams, data under the `/Identity` filter (including a stream's own `/Crypt` filter), and `/Metadata` streams when `/EncryptMetadata` is false. So descriptors (`/NM`, `/Contents`, `/Subtype`) are real for encrypted files, and the matcher and the M6 page filter work on them (`descriptorsAreComplete`). Revisions that disagree about `/Encrypt` are refused.
- **Writing.** Every string and stream of every object the update writes is encrypted in `serialize` with the key of the object number it is written as: MD5 of the file key, the low 3 bytes of the number and 2 of the generation, plus `sAlT` for AES; R6 uses the file key. AES gets a random 16-byte IV, prepended, with PKCS#7 padding, and the stream `/Length` is the ciphertext's. Encrypted strings are written as hex. A rewritten object (a page's `/Annots`, an edited annotation) was decrypted with its own key when read and is encrypted again under the same number, so ciphertext never moves between objects. The cross-reference stream and `/Encrypt` are never encrypted; the trailer (or cross-reference stream dictionary) keeps `/Encrypt` as the same reference and `/ID` exactly as it was (the key depends on `/ID[0]`), and the writer's own verification fails otherwise.
- **The safety checks.** The writer re-reads its output with the same password, and requires it to be encrypted as before with `/Encrypt` and `/ID` unchanged. `SavedFileCheck.verify(…, password:)` opens the read-back with the session password and compares every annotation's decrypted subtype, `/NM` and `/Contents`, not just counts: the added and edited ones against what the writer meant to write (`SaveResult.writtenAnnotations`), every other one against the original. A wrong key gives the right count with garbage text, and the check catches it (`EncryptionTests.aWrongObjectKeyIsCaught`). *(M7 review.)* A key the writer and the reader get wrong in the same way would pass both, so the app also reads the written bytes back through **PDFKit**, which shares none of PDFSave's parsing or crypto (`ReaderDocument.checkWithPDFKit`): unlocked with the session password or the empty one, every added and edited annotation must show with the subtype and `/Contents` the writer meant to write. A failure throws before NSDocument replaces anything.
- **The app.** The inspection, the writer, `SavedFileCheck`, the descriptors after a save and the re-inspection all use `ReaderDocument.sessionPassword`, or none. A save never changes the encryption, so `DocumentKey` (the Keychain entry) stays the same (`EncryptedJournalTests.theDocumentKeyIsTheSameAfterAnEncryptedSave`); *(M7 review)* an encrypted file without an `/ID` is keyed by its `/O` and `/U` alone (`enc:`) rather than by a hash of its first 64 KB, so that holds for it too, and a B7 reload unlocks again with the session password. PDFKit's `allowsCommenting` stays the gate: a file whose `/P` forbids annotating is blocked until the owner password is entered (B6).
- **Unsupported handlers when reading** *(M7 review, D2)*. PDFKit opens a certificate-encrypted (`/Adobe.PubSec`) file as if it were unencrypted and shows blank pages. Once the inspection finds a non-Standard handler, the window's info line (the forms line's mechanism, quiet and dismissible) says Lectern can't decrypt it, so the pages may appear blank; never an alert.
- **Net changes at save time** *(M7 review, D3)*. The writer gets `PendingChanges.netChanges`: an edit of a file annotation followed by its delete is the delete (adds already fold their edits and deletes). Undoing a comment on a saved highlight and then the highlight itself used to leave both, which the writer refuses; the pending list and the undo stack are unchanged.
- **Known gap.** PDFKit on macOS 26 can't unlock any non-ASCII password (CoreGraphics can, given the right bytes, but a `PDFDocument` doesn't follow). Such a file can't be opened in Lectern except with an ASCII owner password, although PDFSave authenticates the same string (`EncryptionTests.pdfKitCantUnlockANonASCIIPassword`).

### 4.4 Link interception and preview (A3, A4)

*Amended 2026-10-29, from M0b Q2, Q7 and Q8. See [spikes/m0b-pdfkit.md](spikes/m0b-pdfkit.md).*

**Interception points.** Intercept link clicks in `mouseDown`, because PDFKit acts on mouse-down, and override `perform(_:)` as a catch-all.

**Classifying actions**
- Classify by `action.type`, not by Swift subclass.
- `Launch` arrives as a URL action with no URL.
- Reading `PDFActionRemoteGoTo.url` from Swift crashes, so never touch it.

**Close PDFKit's side paths**
- Its private "Open Link" context-menu method, which calls `NSWorkspace` directly. The custom context menu from M1 already removes it.
- The `PDFViewDelegate` default, which opens URLs.
- PDFKit's own Force Click gesture recogniser. Remove it, and handle `pressureChange` ourselves.

**`/Fit` destinations.** `/Fit`, `/FitH` and `/FitR` all arrive as "no position", and PDFKit doesn't fit the page. The preview applies fit-to-page itself.

*(Amended 2026-10-29, M2)* Until M3 takes over, PDFKit still follows internal links itself. On macOS 26 a click goes through `PDFView.perform(_:)` (`action.type` "GoTo"), then `go(to: PDFDestination)`.
- `ReaderPDFView` overrides `perform(_:)`. A `GoTo` that moved the view records the departure in the pane's history.
- Named `GoBack` and `GoForward` actions use the pane's history, not PDFKit's own.
- PDFView's own `goBack:`, `goForward:` and page actions are never the menu commands' selectors. A test checks that `ReaderPDFView` responds to none of them.

**Owning link clicks.** `ReaderPDFView` handles clicks on links itself, using annotation hit-testing, instead of PDFKit's default handling. Clicks are routed like this:

| Link target | What happens |
|-------------|--------------|
| `GoTo` or named destination | Jump there and record a history entry |
| `http` or `https` | Open in the default browser; the full URL was shown on hover |
| Any other scheme | Ask for confirmation, then open |
| `GoToR`, `Launch`, form submit | Explain that it's blocked, then do nothing |

**Hover.** An `NSTrackingArea` measures the hover delay of about 0.5 seconds. Hover previews can be turned off in Settings.

**Force Click.** Handled with `pressureChange` events.

**Keyboard**
- A link-focus mode collects the link annotations on visible pages, sorted into reading order.
- Arrow or Tab keys move a drawn focus ring between them.
- Space opens the preview, and Return follows the link.
- Each focused link is exposed to VoiceOver as an accessibility element.

**The preview**
- An `NSPopover` hosts a second, view-only `ReaderPDFView` on the same `PDFDocument`.
- It's scrolled to the destination, with a marker drawn on the target region. For `/Fit` destinations it shows the whole page.
- It has Go, Open in Split and Dismiss actions.

**How M3 builds this** *(Amended 2026-10-29, M3)*
- **Owning links.** `ReaderPDFView` swallows a mouse-down on a link annotation and follows it on the matching mouse-up. It makes itself first responder, because skipping super skips PDFKit's own focus change. `perform(_:)` never calls super; every action goes through `LinkClassifier` (by `action.type`) to `onActivateLink`.
  - The view's `delegate` is an internal object that routes `pdfViewWillClick(onLink:)` and the remote-GoTo callback through the same policy.
  - `openRepresentedLink:` is replaced. `willOpenMenu` strips it unconditionally.
  - The immediate-action recogniser is removed in `init` and on `viewDidMoveToWindow`, and `addGestureRecognizer` refuses it if PDFKit adds it again.
- **Routing.** The pane follows internal destinations and the page-moving named actions (`NextPage`, `PrevPage`, `FirstPage`, `LastPage`, `GoBack`, `GoForward`). Other named actions only beep.
  - Everything else goes to the window. `http` and `https` go to the `URLOpening` seam.
  - A URL with no scheme, a `file:` URL, or a scheme that opens something on this Mac (`afp`, `smb`, `nfs`, `cifs`, `ftp`, `vnc`, `ssh`, `telnet`, `x-man-page`, `applescript`, `x-apple-systempreferences`) is a Launch in disguise. It is blocked with the Launch explanation.
  - Other schemes get a confirmation sheet that shows the URL. `GoToR`, `Launch`, `SubmitForm`, `JavaScript` and any other type get an explanation sheet (`BlockedLink`).
  - While hosting tests, the default opener only records.
- **Hover.** A `Timer` in the common run-loop modes, rather than a dispatch delay. A hover preview closes 0.4 s after the pointer leaves the link, unless the pointer went into the preview.
  - The link under the pointer, or the focused link, is shown in a status line at the bottom of the pane: the full URL for web and other-scheme links.
  - "Preview Links on Hover" (View menu) is stored in `UserDefaults` under `PreviewLinksOnHover` and defaults to on. Tests use in-memory preferences.
- **Force Click.** Stage 2 in `pressureChange` previews an internal link, and the release then doesn't follow it. `quickLook(with:)` never reaches PDFKit over any link: an internal link previews, and other links do nothing.
- **Keyboard.** ⌥⇥ (View ▸ Focus Links) collects the links that intersect the area below the toolbar. They are ordered by page, then by the character index of the link's text (which follows columns), then by geometry.
  - ⇥/⇧⇥ and the arrow keys move, wrapping at either end. Space previews, Return follows, Escape leaves, and any other key leaves and does what it normally does.
  - The ring is an overlay view. Each collected link is an `NSAccessibilityElement` with role link, a label such as "Link to Figure 3, page 4", and a press action. They are added to PDFKit's own children.
- **The preview.** `LinkPreviewController` shows the view through a `LinkPreviewPresenting` seam: an `NSPopover` with `.transient` behaviour in the app, an invisible window in tests.
  - A destination with a position is shown at Fit Width, with a little context above it. An overlay band with a leading bar marks it.
  - `/Fit`, `/FitH`, `/FitR` and unpositioned destinations are shown at Fit Page. PDFKit reports all of them as unspecified, so a `/FitH` top or a `/FitR` rectangle isn't marked.
  - Neither the marker nor the focus ring is ever an annotation.
  - Links inside the preview move it and push onto its own Back stack. Go is the Return key equivalent.
- **Annotation refresh across panes.** `ReaderWindowController.notifyAnnotationsChanged(from:)` re-binds every other pane (`ReaderPDFView.rebindDocument()`: `show(nil)`, `show(document)`, restore the anchor). It then re-binds the source pane too.
  - Re-binding moves page ownership (M0b Q7), so without that a second change made in the source would show only in the other pane. The test covers three changes alternating between the panes.
  - Re-binding clears each pane's text selection, and the source pane's too, which M4 must allow for. The fit reference page and zoom are kept.
  - Measured: 22–33 ms per call (both panes re-bound) on a 6-page fixture, M3 Pro, debug build. Each pane keeps its place. Flicker isn't checked: offscreen captures don't show annotations (M0b Q11).

### 4.5 Keeping your place

A `ReadingAnchor` records a page index plus a point in that page's coordinates, plus the zoom.

The pane captures the anchor before any of these, and restores it afterwards:
- zooming,
- resizing,
- changing layout (B1),
- rotating (B9),
- reloading (B7).

The same type is stored as the reading position (A2) and used for history entries (B2).

**Zoom and fit modes** *(Amended 2026-10-29, M1)*
- `ReaderPDFView` turns PDFKit's `autoScales` off and owns the zoom mode itself.
- **Fit Page and Fit Width** are computed from `rowSize(for:)`, which accounts for two-up spreads, cover-page layout, page margins and rotation. They are measured against the area below the toolbar (the safe area, because the window uses a full-size content view).
- A fit mode is recomputed on every frame or safe-area change, and after every layout or rotation change.
- A pinch or other direct zoom turns the mode into a fixed scale.
- Until M2's anchors land, layout and rotation changes keep the current page in view but not the exact point on it.

**How the anchor works** *(Amended 2026-10-29, M2)*
- **What it records.** The anchor is the page-space point at the top-left corner of the area below the toolbar (the safe area). Page space is the unrotated crop box, so the same anchor holds across a rotation.
- **What restoring does.** It scrolls that point back to the same corner, as far as the document's edges allow. It does not apply the anchor's `scale`: zoom belongs to `ViewSettings`.
- **One kept anchor.** `ReaderPDFView` keeps one anchor from the last restore, or from where the user last scrolled to. Zoom, resize, layout and rotation run inside `preservingAnchor`, which restores that anchor rather than measuring again. Reload restores it too. This avoids three problems:
  - drift over the many steps of a live resize,
  - the moment mid-resize when `safeAreaInsets` reads as zero,
  - content that a later layout pass moves, such as a scroller appearing or disappearing with "Show scroll bars: Always". A scroll the user didn't make puts the kept anchor back.
- **What counts as the user scrolling.** Scroll-wheel, mouse, gesture and non-command key events in the view (a local event monitor), and nothing else. A pinch keeps whatever place it leaves.
- **PDFKit workarounds, measured on macOS 26:**
  - Scrolling clamps the clip view to the document by hand. PDFKit's `constrainBoundsRect` snaps to rows in two-up layouts, which moved the reader by about a line.
  - The anchor is measured from a point on the page. `convert(_:to: page)` for a point beside the page, in the gutter, doesn't invert `convert(_:from: page)`.
- **History and stored positions** use the same type. A jump to a page lands on the page's visual top-left corner, rotation included. A destination with unspecified coordinates (`/Fit`) does the same.
- **Search results** are shown a third of the way down the area below the toolbar. PDFKit's `go(to: PDFSelection)` ignores the safe area.

**Distraction-free mode** *(Added 2026-10-29, M5)*
- View ▸ Enter Distraction-Free Mode (⇧⌘F) hides the toolbar, the sidebar and the split's focus bar and close buttons, inside every pane's anchor capture. Escape or ⇧⌘F leaves; ⌘F leaves too, because the search field is in the toolbar.
- **The toolbar is detached, not hidden.** Toolbars that share an identifier share their visibility, and visibility is autosaved, so hiding one would hide every window's toolbar for good.
- **Nothing is stored.** Collapsing the sidebar here isn't the user's choice, so the document's `ViewSettings.sidebar` is untouched. The mode belongs to the window for the session, and the session restore brings it back.
- Settings ▸ General can make it enter full screen as well; leaving it then leaves full screen.

### 4.6 Concurrency

**Main thread:** all UI, and the `PDFDocument` shared by the panes.

**Search (B8):** uses PDFKit's asynchronous find, whose results arrive through delegate callbacks.

**Thumbnails**
- Generated lazily by a background actor.
- The actor opens its own `PDFDocument` from the same bytes.
- Results are cached in memory, keyed by page index and the size and scale they were drawn at.

**As built in M2** *(Amended 2026-10-29)*
- **`PageRenderer`** (ReaderKit) is an actor holding its own `PDFDocument`, unlocked with the session password. It returns `CGImage`s and applies the view rotation (B9) to its own pages. Its cache holds up to 400 images, keyed by page, pixel size and rotation. It is rebuilt when the document reloads.
- **Thumbnail rows** ask for their image only when the table creates them. A reused row cancels its request, so pages that scrolled past are skipped before they're drawn.
- **`TextInventory`** is a second actor with its own copy of the document. It finds the pages with no text for B8's messages, so the main thread never reads `page.string` for that.
- **`DocumentSearch`** (ReaderKit) wraps `beginFindString`. It listens to the find notifications rather than taking over the document's delegate, and coalesces updates to every 100 ms.
  - Whole Word reads only the text of pages that have matches, and caches it.
  - Excerpts are built when a row is shown.
  - The results list shows the first 5,000 matches; the count covers them all.
  - Page highlights are replaced at most twice a second while results stream in, and once more at the end *(Amended 2026-10-29, M2 review)*.
  - *(Amended 2026-10-30, M6)* **The 100 ms coalescing is a run-loop timer** in the common modes, not `DispatchQueue.main.asyncAfter`.
    - PDFKit posts its find notifications on the main thread itself (the M6 review counted 234 on the main thread and none off it).
    - A block queued with `asyncAfter` can't run while the main thread is already inside a main-queue block. So when the run loop is spun from within one, the list stayed empty until the search ended. That happens in a modal session, a tracking loop, or a `@MainActor` test spinning the run loop: the M6 performance test saw 7.5 s on the 3,270-page manual.
    - Under the app's top-level event loop, `asyncAfter` showed the first results after 0.21 s, with 43 updates. So the empty list was most likely a test-harness effect, not something users saw.
    - The timer fires in any run loop. It's kept because it's more robust, and `ReleaseTests.resultsReachTheListWhileALongSearchRuns` holds it to that.

**Main-thread cost of opening** *(Amended 2026-10-29, M2 review)*
- **What is kept off the main thread.**
  - The renderer and the text inventory open their own documents lazily, on their actors.
  - Original rotations are read from CoreGraphics' page dictionaries, which avoids creating a `PDFPage` for every page.
  - Page labels are read only when needed.
  - The view rotation isn't reapplied when it hasn't changed.
  - Thumbnail rows have a fixed height, so the table doesn't measure every page.
  - The store reuses the parsed `/ID`.
- **Measured on a generated 2,000-page file** (`OpeningPerformanceTests`).
  - Opening adds about 15–17 ms over PDFKit's own work (read, parse and layout, about 135 ms) once the window itself is taken out.
  - Building the window costs about 35–41 ms for any document, so the total over PDFKit is about 50–59 ms.
  - Before these changes, the total over PDFKit was about 400 ms.

**The annotation list** *(Added 2026-10-30, M6)*
- `annotationList` reads only the pages that can hold a listed annotation: those the background inspection's descriptors list one on, plus every page an annotation was added to or put back on this session (`AnnotationEditor.pagesThatCanHoldListedAnnotations`). Reading every page's annotations took 0.53 s on the main thread for the 3,270-page manual's 18,553 links; the list now takes 1.5–2.7 ms there.
- Until the inspection has run, or when it couldn't read the file's annotations (malformed, or encrypted in a way PDFSave doesn't support: `AnnotationFileInfo.descriptorsAreComplete` is false), every page is read as before. *(Amended 2026-10-30, M7: supported encrypted files are decrypted, so their descriptors are complete.)*
- `AnnotationMatcher` indexes a batch by page and by `/NM`, so matching a page costs that page's annotations, not the whole file's.

**Saving**
- Serialising and verifying run off the main thread, from a snapshot of the annotation state.
- The swap into place happens on the main thread through `NSDocument`'s safe-save.
- *(Amended 2026-10-29, M4b)* **As built, the write runs on the main thread.** `canAsynchronouslyWrite` is false, so `NSDocument` calls `write(to:…)` on the main thread, and the serialising and the read-back check run there. M4a measured one highlight on a 1,000-page file at about 0.015 s in a release build, including the writer's own verification. Moving it off the main thread is left for when a measured case needs it.
  - What does run in the background is the check when a document opens or is saved: `Saveability`, every annotation's descriptor and the SHA-256, in one detached task. Annotation actions wait for it, and say so if the user is quicker.
  - *(Amended 2026-10-30, M6)* **The measured case.** One highlight saved into the 3,270-page, 15 MB PostgreSQL manual blocks the main thread for 0.73 s in an optimised build (M3 Pro): 0.39 s in the writer with its verification, 0.33 s in `SavedFileCheck`, which re-reads the file and its 18,553 annotations. Both are A1's safety checks. It stays on the main thread for 1.0, as a known limitation; if the baseline M1 makes it worse than about 1.5 s, the write moves to `canAsynchronouslyWrite`.

## 5. Internal data structures

| Type | Module | Purpose |
|------|--------|---------|
| `ReadingAnchor` | ReaderCore | `pageIndex`, `pointInPage`, `scale`. Used for keeping your place, the stored position, and history entries |
| `HistoryStack` | ReaderCore | Back and forward lists of `ReadingAnchor`, one per pane. A search session adds one entry (B2). *(Amended 2026-10-29, M2: the entry is the position when the session began, added when the first result is shown, so a search that never moves the view adds none. Back or Forward inside a session restarts it from the new place. Up to 100 entries each way.)* |
| `PaneID` | ReaderCore | Names a pane (`primary`, `secondary`). Keys the stored per-pane history *(Added 2026-10-29, M2)* |
| `DocumentIdentity` | ReaderCore | File bookmark data, the PDF's internal `/ID` pair, page count, file size, last known path (A2). *(Amended 2026-10-29, M2: also a fingerprint and a file number. The fingerprint is a SHA-256 of the size and the first and last 64 KB, and tells a changed file from an unchanged one. The file number is "device:inode", so a renamed or moved file without an `/ID` finds the record whose bookmark to resolve. Stays in ReaderCore, as this table says. The task's "in Persistence" means stored by Persistence. `DocumentMatcher`, next to it, holds the pure matching rules.)* |
| `ViewSettings` | ReaderCore | Pages, Scrolling, cover-page and right-to-left overrides (B1), rotation (B9), zoom mode. The sidebar section is added with the sidebar in M2 *(Amended 2026-10-29, M1)*. *(Amended 2026-10-29, M2: `sidebar` holds visibility and section. Every key decodes with a default, so state from other versions loads.)* |
| `PageNumbering` | ReaderCore | Page labels, and whether the catalog defines `/PageLabels`. PDFKit makes up "1", "2"… otherwise. Go to Page matches a defined label first, ignoring case, then a page number *(Added 2026-10-29, M2)* |
| `SearchOptions`, `SearchText`, `SearchSummary` | ReaderCore | Match Case and Whole Word, the whole-word test and result excerpts, and the status line, including "This document has no searchable text" and the count of pages without text (B8) *(Added 2026-10-29, M2)* |
| `DocumentStateStore` | Persistence | Reads and writes `DocumentState` (§6). Matches an opening file to its record *(Added 2026-10-29, M2)* |
| `DocumentLayoutHints` | ReaderCore | The catalog's `/PageLayout` (`TwoPageRight`/`TwoColumnRight` puts the cover page alone) and `/ViewerPreferences /Direction /R2L`, read through `CGPDFDocument` once the document is unlocked. These are the defaults the `ViewSettings` overrides replace (B1) *(Added 2026-10-29, M1)* |
| `DocumentKey` | ReaderCore | `id:` plus the trailer's first `/ID` element as hex. Encrypted files add `;enc:` plus a SHA-256 of the encryption dictionary's `/O` and `/U` entries, because the `/ID` survives re-encryption with another password. Files with no `/ID`, or an unreadable encryption dictionary, get `sha256:` plus a hash of the first 64 KB. Readable while the document is locked. Keys remembered passwords (B6) *(Added 2026-10-29, M1)* |
| `DocumentPasswordStore` | Persistence | Protocol for remembered passwords, keyed by `DocumentKey`. `KeychainPasswordStore` in the app, `InMemoryPasswordStore` in tests *(Added 2026-10-29, M1)* |
| `DocumentState` | Persistence | Identity, last anchor, per-pane history, reader bookmarks, view settings. Written to disk as JSON |
| `AnnotationChange` | PDFSave | Add, edit or delete of one annotation, with its full properties. Feeds the crash journal and the writer |
| `PendingChanges` | PDFSave | The ordered list of unsaved `AnnotationChange`s. Edits and deletes of an annotation added since the last save fold into its add; a colour or contents edit that returns to the file's value is withdrawn *(Added 2026-10-29, M4b)* |
| `SavedFileCheck` | PDFSave | The read-back after a save: the bytes, the original as a prefix, the annotation count and every added `/NM` *(Added 2026-10-29, M4b)*. *(Amended 2026-10-30, M7: opened with the session password, and every annotation's decrypted subtype, `/NM` and `/Contents` compared.)* |
| `StandardSecurity`, `EncryptionProblem` | PDFSave | The Standard security handler: password authentication, the file key, per-object keys, decrypting what is read and encrypting what is written; and why an encrypted file can't be saved into *(Added 2026-10-30, M7)* |
| `JournalKey` | Persistence | The key an encrypted document's crash journal is sealed with: HKDF-SHA256 of the file key, salted with the `DocumentKey` *(Added 2026-10-30, M7)* |
| `AnnotationJournal`, `JournalEntry` | Persistence | The crash journal (§6) *(Added 2026-10-29, M4b)* |
| `AnnotationColorPreset`, `AnnotationKindName` | ReaderCore | The six named colours (B4), names for other apps' colours, and which kinds are listed and can be recoloured *(Added 2026-10-29, M4b)* |
| `AnnotationEditor` | App | One per `PDFDocument`. Applies each user action to `PendingChanges` and to PDFKit, matches file annotations page by page, and registers the inverse action for undo. So undo works across a save: undoing a saved add appends a delete, and undoing a saved delete recreates the annotation under a new `/NM` (markup and notes only) *(Added 2026-10-29, M4b)* |
| `LinkTarget` | ReaderKit | A link's destination or action, classified for routing (§4.4) |
| `ReaderBookmark`, `ReaderBookmarks`, `BookmarkExport` | ReaderCore | A named `ReadingAnchor` (A2), the rules for ⌘D (a bookmark "here" is one on the page being read; ⌘D removes the one nearest the anchor, never more than one), reading order, renaming, and the versioned JSON export ([bookmarks-export.md](bookmarks-export.md)). Stored as made and clamped only where shown, followed or exported, so a file that shrinks and grows back gets its bookmarks back; one damaged stored entry loses only itself *(Added 2026-10-29, M5; amended after the M5 review)* |
| `SessionRestorePolicy` | ReaderCore | Reopen last session's documents: as macOS says, always, or never *(Added 2026-10-29, M5)* |
| `SessionState`, `SessionRestorer` | App | The windows, tab order, selected tab, frames and distraction-free mode at quit, and reopening them (§6) *(Added 2026-10-29, M5)* |
| `SessionCoordinator`, `ReviewForwarder` | App | When the session is restored, saved or left alone, and when the empty state shows; how the quit's unsaved-changes review ended (§6) *(Added after the M5 review)* |
| `UpdateController` | App | The opt-in update flow (A4, §7): the first-launch question, the setting, Check Now. Creates Sparkle only when needed *(Added 2026-10-29, M5)* |
| `KeyboardShortcutCatalog` | App | Help ▸ Keyboard Shortcuts, read from the main menu *(Added 2026-10-29, M5)* |

## 6. Storage

**Per-document state (A2)**
- One JSON file per document, at `~/Library/Application Support/<bundle-id>/Documents/<uuid>.json`.
- Files are written atomically, and only after a debounce interval.
- **Why JSON:** a person can read it, it's trivial to export (A2's bookmark export), and the volume is small. There's no need for SQLite or SwiftData.
- **Identity index:** `index.json` maps document identities to UUIDs.

**As built in M2** *(Amended 2026-10-29)*
- **Layout.** `index.json` sits beside `Documents/`, in `Application Support/<bundle-id>/`. Each state file holds the identity, the last anchor, per-pane history and `ViewSettings`, which includes the sidebar.
- **Writing.** Changes are kept in memory and written atomically after a 1 s debounce, on the store's private queue. The window flushes when it closes, and the app flushes when it quits. The reading position is saved half a second after scrolling settles. The root folder is injected: package tests use temporary folders, and while the app hosts its tests the shared store lives in a temporary folder too.
- **Matching an opening file (A2).** Only records related to the file are considered: the same path, file number, permanent `/ID` or fingerprint. Then:
  1. A record whose security-scoped bookmark resolves to this file is the same document. That covers moves and renames. If the fingerprint changed, the anchor and history are clamped to the new page count.
  2. Otherwise, a record with the same permanent `/ID`, or the same fingerprint when there's no `/ID`, whose bookmark no longer resolves is adopted.
  3. If that record's bookmark resolves to another file that still exists, this file is a duplicate: it gets a new record copied from the original's state.
  4. Otherwise a new record starts.

  A fresh bookmark is recorded on every open, which replaces a stale one.
- **Never losing the index** *(Amended 2026-10-29, M2 review)*.
  - An `index.json` that can't be read or decoded is moved aside (`index.unreadable-<time>.json`), and the index is rebuilt from `Documents/*.json`. A missing index is rebuilt the same way.
  - State files are written before the index. If any state file fails, the index waits, and the failed records are retried after 5 s.
- **Pruning (privacy).** Each record keeps a path and a bookmark, so:
  - Records not opened for 180 days, and any beyond the newest 500, are dropped together with their state files.
  - File ▸ Open Recent ▸ Clear Menu also forgets the stored state of the files it clears.
- **Comparing paths.** Paths are compared in their canonical form. Inside the sandbox, `resolvingSymlinksInPath` leaves `/tmp` as it is, while a resolved bookmark gives `/private/tmp`.
- **A file moved while it is open.** The identity is refreshed from the new URL that file coordination reports. `NSDocument` may not have updated `fileURL` yet.
- **First open.** A document with a table of contents opens the sidebar on that section.

**Crash journal (A1)**
- `Journal/<uuid>.json` holds the unsaved `AnnotationChange` list.
- It's rewritten after every change (debounced), and deleted after a successful save or an explicit discard.
- When the document next opens, the app offers to restore it.

**As built in M4b** *(Amended 2026-10-29)*
- `AnnotationJournal` (Persistence) lives in `Journal/`, beside `Documents/` and `index.json`. The `<uuid>` is the document's stored-state ID. Each file holds the SHA-256 of `originalData`, the change list, and when it was written. Writes are atomic, debounced by 0.5 s, on a private queue.
- **The live journal is deleted** after a successful save or a reload once the journal check has run (B7 Reload and Save a Copy end in a reload), and when the document closes with unsaved annotations (which only happens after Don't Save). A Save As gives the new file its own stored record, so its journal is never filed under the original's ID.
- **Before the journal check** *(Amended 2026-10-29, M4b review)*, the live journal is a crash journal nobody has seen: nothing is journaled over it, and a save or a reload sets it aside instead of deleting it.
- **On open,** once the background check has the hash, one journal is offered: the live `<uuid>.json` if there is one, otherwise the oldest kept one.
  - *(Amended 2026-10-29, M4b review)* **It is set aside before the question appears**, to `Journal/<uuid>.kept-<time>.json`. The document's new changes, saves, reloads and closes only ever write or delete the live `<uuid>.json`, so nothing that happens while the question is open can overwrite or delete it.
  - *(Amended 2026-10-29, M4b review)* **A reload or a save before the check** (the file rewritten, or a Save As, while the background check runs) sets the live journal aside instead of deleting it, so it is still offered: as no longer fitting after a reload, and on the original's next open after a Save As. A reload to a file that needs a password leaves the live journal for the check after unlocking. Only after the check do a reload and a save delete the live journal, which then holds this session's own changes.
  - The same hash offers **Restore** or **Discard**. When the answer comes, the document must still be the same model with the same hash; if it reloaded meanwhile, the journal is explained as no longer fitting instead. Restore replays the changes onto the pages, all or nothing: if an edit or delete can't find its annotation, or new changes were made meanwhile, nothing is applied and the journal stays kept.
  - A different hash, or a file that can't be read, explains that the annotations no longer fit and offers **Discard** or **Keep for Now**.
  - **Every answer acts on that one file.** Discard deletes it; a successful Restore deletes it only after the replayed changes have been written to the live journal (flushed, not left to the debounce, and the write confirmed), and never when the offered file is itself the live journal; if that write fails, the offered file stays kept. Keep leaves it kept. Other kept journals are never touched and are offered on later opens. No journal is ever deleted without the user seeing it.
- Restoring isn't an undoable action.

**Encrypted documents** *(Added 2026-10-30, M7)*
- A journal must not leave an encrypted document's notes on disk in plain text. Its change list is sealed with AES-GCM (`JournalEntry.sealed`, nonce, ciphertext and tag together) under `JournalKey`: HKDF-SHA256 of the PDF's file key, salted with the SHA-256 of its encryption dictionary's `/O` and `/U` (`PDFSaveDocument.encryptionDigest`, which lives exactly as long as the file key; *M7 review*: a `DocumentKey` salt changed on every save of a file without `/ID`), with the info string `io.github.ronimoe.Lectern annotation journal v1`. The SHA-256 of the original is authenticated with it, so a payload can't be moved to another file's entry. The metadata (the file's UUID name, the hash, the date) stays plain, so a journal can be matched and explained without the key.
- The key exists only in memory, and only once the document is unlocked and inspected (`AnnotationFileInfo.journalKey`). The file key is the same whichever password opened the file, so the user and the owner password give the same journal key, and a save doesn't change it.
- **Fail closed.** An encrypted document without a key (its encryption unsupported) journals nothing; a seal that fails writes nothing. Never the plain text.
- **Restore** runs only after unlocking, since the journal check waits for the inspection. A sealed journal that doesn't open (no key, another key, damage) is `.unreadable`: it is explained, kept, and deleted only if the user chooses Discard, like any other kept journal.

**Other storage**
- **Recent documents:** the system recents list kept by `NSDocumentController`.
- **Session restore:** AppKit window restoration, which brings back windows, tabs, splits and each pane's anchor (B3).
  - *(Amended 2026-10-29, M5)* **Lectern's own state, not AppKit's restoration.** `SessionRestorer` writes `Session.json` beside `index.json`: the windows front to back, each with its tabs (a security-scoped bookmark and the path), the selected tab, the frame, and whether it was in distraction-free mode. Each pane's place, the split, zoom and sidebar aren't in it: they are the per-document state (A2), which reopening the document restores.
  - **Why not AppKit's.** AppKit discards its state when macOS closes windows on quit, so Settings' "Always" couldn't work; a missing file would go through `NSDocumentController`'s error path; and none of it can be driven in a test. `isRestorable` is off on every Lectern window so the two never both reopen a document.
  - **When.** Settings ▸ General ▸ Reopen documents on launch: "As set in System Settings" (the default: restore only when Desktop & Dock ▸ "Close windows when quitting an application" is off, `NSQuitAlwaysKeepsWindows`), Always, or Never. Never deletes the file, so no list of open files is kept.
  - **Saving.** On every document open and close, so a crash still restores, and once at quit before the unsaved-changes review closes anything (`reviewUnsavedDocuments`), or at `applicationWillTerminate` when there was no review.
  - **Test launches.** With `-ApplePersistenceIgnoreState YES` on the command line (the test host, and `scripts/release/verify-dmg`), the session is neither restored nor written, and the first-launch update question isn't asked. Only the argument domain counts: the same key set with `defaults write -g` changes nothing.
  - *(Amended after the M5 review)* **Quits.** A quit the user cancels in the unsaved-changes review (`ReviewForwarder` stands in for the review's delegate and passes the answer on) turns saving back on. A quit while last session is still reopening leaves the file alone. `SessionCoordinator` holds this logic so it can be tested; `AppDelegate` and `ReaderDocumentController` only forward events.
  - *(Amended after the M5 review)* **The file is written only while it could be used:** with Never, or "As set in System Settings" while macOS closes windows on quit, it is deleted instead.
  - *(Amended after the M5 review)* **Restoring, in detail.** Security-scoped access starts before the file is looked for, and is given back for every tab skipped (gone, failed to open, already open, listed twice). A file listed twice comes back once. A damaged frame, or one smaller than 320 × 240, is ignored. Windows are ordered in without becoming key; only the front window becomes key at the end, and restored windows ask for a password (or read the Keychain) only when they become key, one at a time.
  - **Restoring.** At launch, each window's documents open without display, then the first is shown with tabbing off (so it doesn't join another window) and the rest are added as tabs in order. The empty state waits until the restore ends. A file that is gone, or fails to open, is skipped without a message. An encrypted document asks for its password again unless the Keychain read succeeds; a failed or declined read counts as not remembered (B6).
  - **Not done:** full screen isn't restored, and a tab dragged into another window is saved only at the next open, close or quit.
- **Settings:** `UserDefaults`.
  - *(Amended 2026-10-29, M5)* Keys: `ReopenDocumentsOnLaunch`, `PreviewLinksOnHover`, `DistractionFreeEntersFullScreen`, `annotationAuthor` (empty unless typed, B4), `AnnotationColor`, `CheckForUpdatesAutomatically` (absent until the first-launch question is answered). Sparkle keeps its own `SU*` keys, but only once the user has opted in or chosen Check Now.
- **Passwords:** Keychain, only when "Remember in Keychain" is ticked (B6).
  - *(Amended 2026-10-29, M1)* These are generic-password items in the file-based login keychain: service `io.github.ronimoe.Lectern.document-password`, with the `DocumentKey` as the account.
  - The data-protection keychain would need a `keychain-access-groups` entitlement, which needs a team-signed build.
  - A remembered password is tried when the document opens. It unlocks a locked document, and a remembered owner password also lifts a restricted document's limits. A remembered password that no longer gains access is deleted; because the key includes the encryption entries, the entry can only be this file's own. On an open document only the owner password counts as gaining access, since PDFKit's `unlock` then accepts any string.
  - **Known limitation while builds are ad-hoc signed:** each build has a different code signature, so a new build reading an item saved by an older one may get a Keychain access prompt. This is unverified.

**Sandbox: on.** The App Sandbox is optional for direct DMG distribution, but turning it on limits the damage a hostile PDF could do through the rendering engine. It means:

| Entitlement or setting | Why |
|------------------------|-----|
| Read-write access to files the user chooses | Opening and saving documents |
| Security-scoped file bookmarks | `DocumentIdentity`, so state survives restarts (A2) |
| Outgoing network connections | Only so the opt-in update checks can work (A4) |
| Printing | `com.apple.security.print`, so Print works inside the sandbox *(Added 2026-10-29, M1)* |
| Sparkle's `mach-lookup` temporary exception | Sparkle's installer service runs outside the sandbox (A4) |
| `com.apple.security.cs.disable-library-validation` | Needed for as long as the app is signed ad-hoc. Without it the hardened runtime refuses to load the embedded Sparkle framework |

*(Amended 2026-10-29, M5.)* Both Sparkle rows are now in `App/Lectern.entitlements`: the mach-lookup exception for `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki`, and `disable-library-validation`. `scripts/release/build-dmg` refuses a build without them or without the embedded framework. Sparkle's downloader service isn't used (`SUEnableDownloaderService` off), because the app already has `network.client`.

*(Amended 2026-10-29, from the M0c prototype, [spikes/m0c-platform.md](spikes/m0c-platform.md).)*
- **The sandbox stays on.** Bookmarks and the container both survived ad-hoc rebuilds in both directions.
- **Library validation is turned off.** That is a known weakening of the hardened runtime, accepted so that Sparkle updates arrive without the download quarantine; users then bypass Gatekeeper once instead of on every release.
- **No other dynamic frameworks.** Everything else, including all LecternKit products, stays statically linked.

Opening links in the browser goes through `NSWorkspace` and needs no network entitlement.

## 7. Third-party dependencies

The policy is to use system frameworks first. Every dependency shipped inside the app must be compatible with GPL-3.0.

| Dependency | Use | License | Ships in app |
|------------|-----|---------|--------------|
| PDFKit, AppKit, SwiftUI, Security (Keychain) | Core | Apple system frameworks | Built into macOS |
| Sparkle 2 | Opt-in update checks (A4) | MIT, compatible | Yes |
| PDFium or MuPDF | Only if the A1 prototype picks it | BSD-3 / AGPL-3.0 | Only if chosen |
| qpdf | Generating test files and the structural check (§3.2) | Apache-2.0 | No, developer tool |
| pyHanko | Generating signed test files | MIT | No, developer tool |

*(Amended 2026-10-29, M5)* **Sparkle 2.10.1, pinned with `exactVersion` in `project.yml`.** It stays: Sparkle installs updates between ad-hoc signed builds, so the notify-only fallback isn't needed.
- **Why it works.** An ad-hoc build's designated requirement is its CDHash, so the old and new builds never satisfy each other's, and Sparkle's code-signing check always fails between them. Sparkle's `SUUpdateValidator` (read in the 2.10.1 source for M0c) accepts an app update when *either* the EdDSA signature verifies against the old app's `SUPublicEDKey` *or* the code signatures match. The EdDSA signature alone carries it.
- **Proof.** `scripts/release/sparkle-e2e` builds the M0c probe twice with `App/Lectern.entitlements` (two different CDHashes, no `get-task-allow`), serves an appcast from 127.0.0.1 and drives a headless `SPUUserDriver`. Run on 2026-10-29 (macOS 26.6.2); the output is in [spikes/platform-probe/results/m5-sparkle-e2e.txt](../spikes/platform-probe/results/m5-sparkle-e2e.txt):
  - an archive signed with another key was refused ("improperly signed", `SUSparkleErrorDomain` 4005) and v1 stayed installed;
  - the archive signed with v1's key installed, and Sparkle relaunched it as v2, still sandboxed, with v2's CDHash, a valid signature and no quarantine;
  - no dialog window appeared. It installed into a temporary folder, not `/Applications`.
- **How Lectern uses it.** `UpdateController` asks once at first launch (default: don't check) and keeps the answer in its own preference. Sparkle isn't created until the user opts in or chooses Check Now, so declining means Sparkle never runs and nothing goes over the network. Info.plist turns off Sparkle's own permission prompt (`SUEnableAutomaticChecks` false) and automatic installs; the system profile is never sent; scheduled checks are at most daily. Sparkle's standard windows show progress and ask before installing.
- **The key.** An Ed25519 key in a file, `~/.config/lectern/sparkle_ed25519_private.key` (mode 600), made by `scripts/release/sparkle-key.swift` without the login Keychain. The file is created by `open(2)` with `O_CREAT | O_EXCL` and mode 600 before anything is written; `scripts/test.sh` checks the mode under `umask 000` and that an existing key is never replaced. Sparkle's `generate_keys` keeps its key in the Keychain, which its ad-hoc signed `sign_update` can't read without a prompt (M0c, experiment 3). The public key is `SUPublicEDKey` in `App/Info.plist`. Losing the private key means installed copies can never be updated by the app again.
- **Not verified:** Sparkle's standard windows, HTTPS from GitHub Releases (the test used plain HTTP on 127.0.0.1), scheduled checks firing, and an update in `/Applications` with this setup (M0c did `/Applications` with its own).

## 8. Build and distribution

**Project setup** *(Amended 2026-10-29)*
- The Xcode project is generated by **XcodeGen** (MIT, developer tool) from `project.yml` and isn't committed. Hand-editing `project.pbxproj` is error-prone for agents and for contributors, and a text spec merges cleanly.
- All library code lives in one local package, `Packages/LecternKit`, with five targets: ReaderCore, PDFSave, Persistence, ReaderKit and ReaderUI.
- `scripts/test.sh` regenerates the project and runs `swift test` and `xcodebuild test` headlessly.
- Builds are signed ad-hoc (`CODE_SIGN_IDENTITY=-`) with the hardened runtime on, because there's no Developer ID yet.

**Continuous integration** *(Amended 2026-11-01, issue #34)*
- **GitHub Actions, on every pull request and every push to `main`.** The repository is public, so standard hosted runners cost nothing. `.github/workflows/test.yml` reads the repository and nothing else: no secrets, and never the Sparkle key. The only key it makes is the throwaway one `scripts/test.sh` uses to test `sparkle-key.swift`.
- **No hosted runner fits the whole suite.** No GitHub-hosted runner has macOS 26 with Xcode 27. The `xcode-27` preview image runs macOS 27, and `macos-26` has Xcode 26.6 at most. So CI is split:
  - **`macos-26`, Xcode 26.6:** `scripts/test.sh --no-app`. That covers the LecternKit package tests with every corpus tool, the sparkle-key check and the installer harness. Xcode 26.6 is Swift 6.3, not the 6.4 used in development; that is within `Package.swift`'s tools version 6.2. If LecternKit adopts 6.4-only syntax, this job breaks and has to move.
  - **`macos-26`:** `scripts/release/test-install` on its own as well, because `install.sh` runs straight from `main`. It needs no downloads, so it reports within a minute.
  - **`xcode-27`, Xcode 27.1, run by hand only** (`workflow_dispatch` with `full-suite`): the whole `scripts/test.sh`. Everything builds and runs in the runner's session, but on macOS 27 one package test and 22 app tests fail on behaviour the tests record for macOS 26, most of it in the M0b PDFKit record.
- **The app-hosted tests stay local.** Xcode 26.6 can't compile them, and macOS 27 isn't the platform they describe. `scripts/test.sh` on a developer Mac with macOS 26 and Xcode 27 is still needed before merging a change to the app.

**Release (B5)** *(Amended 2026-10-29: no Developer ID)*
1. Archive a Release build: `xcodebuild archive`, signed ad-hoc with the hardened runtime on and no `get-task-allow`.
2. Package the DMG and publish it on GitHub Releases.
3. Sign the update archive with Sparkle's EdDSA key. The private key is kept off the repo and backed up offline.
   - *(Amended 2026-10-29, M5)* `build-dmg` also writes `Lectern-<version>.zip`. `scripts/release/sign-update <zip>` signs it with `sign_update --ed-key-file` from the pinned Sparkle, checks the key's public half against `SUPublicEDKey`, verifies the signature, and adds an item to `build/release/appcast.xml` (an item for the same build number is replaced). Both files are uploaded to the release; the feed is `https://github.com/ronimoe/pdf-reader/releases/latest/download/appcast.xml`.
4. Publish a Homebrew cask in our own tap, `ronimoe/lectern`.
   - The cask removes the download quarantine after installing, through `postflight`. The official `homebrew/cask` rejects apps that fail Gatekeeper, so it can't host this app.
   - *(Amended 2026-10-29, M6a)* It leaves `auto_updates` unset: the in-app updater is opt-in and off by default, so `brew upgrade` must handle upgrades.
5. **User install instructions** are in `docs/INSTALL.md`, written in M6:
   - Homebrew from the tap,
   - the DMG with System Settings → Privacy & Security → **Open Anyway**,
   - building from source.

   The Control-click → Open bypass no longer exists on macOS 15 and later.

*(Amended 2026-10-30, M6)* **As released.**
- **Version.** `MARKETING_VERSION` 1.0.0 and `CURRENT_PROJECT_VERSION` 1 in `project.yml`. The build number is what Sparkle compares, so it goes up by one with every release. `CHANGELOG.md` records each release.
- **Licences in the app and on the DMG.** The app bundles `LICENSE` (GPL-3.0), `Acknowledgements.txt` (Sparkle 2.10.1's MIT licence verbatim, with the notices for the code it bundles) and `known-limitations.md`, shown under Help ▸ Licence, Acknowledgements and Known Limitations. The About panel shows the version and build, the copyright, the source repository and the no-telemetry line. `build-dmg` adds `License.txt` and `Acknowledgements.txt` to the image, below Lectern and the Applications link in a "drag to Applications" window (`packaging/dmg/`, added after M7). Sparkle is the only bundled third-party component: `Contents/Frameworks` holds only `Sparkle.framework`, and LecternKit is linked statically.
- **No UI when checking a build.** `verify-dmg` no longer opens the app with a window. It runs the copied app's executable directly with `-LecternSelfCheck` (`SelfCheck`, App). `main.swift` handles that argument before `NSApplication` exists, so no window, Dock icon, alert or menu bar can appear. It runs inside the user's real sandbox container (*(Amended after the M6 review)*: earlier wording here said no state is read or written). It opens no document, and never touches `Session.json`, the crash journal, recent documents, the Keychain or Sparkle, which it never creates. The check covers:
  - the bundle and Info.plist promises,
  - Sparkle's version and that it's the only framework,
  - the entitlements of the running process (`SecTaskCopyValueForEntitlement`), and that it has no `get-task-allow`,
  - that the kernel reports the process sandboxed, inside its container,
  - PDFKit and the incremental writer on a PDF made in memory.

  The script requires exit 0 within 30 s, no window owned by the process (polled every 0.1 s while it runs, which is under a second), and no crash report. The window counter must first see the Dock's windows, and an error from it fails the run rather than counting as none.
  - **Unexplained:** a probe that the sandbox refuses to read a file outside the container was tried and dropped. Started directly from a shell, the self-check read a file in `$TMPDIR` and one in the home folder, although the kernel reported the process sandboxed and it ran in its container. The xcodebuild-hosted test host can't read the repository, so the direct launch is the likely difference, but that is inferred, not shown. A normally launched copy still has to be checked by hand ([release-checklist.md](release-checklist.md) §5).
- **Publishing is manual** ([release-checklist.md](release-checklist.md)): tag `v1.0.0`, upload the DMG, its `.sha256`, the zip and `appcast.xml` to a full (not draft, not pre-release) GitHub Release, and push the cask to `ronimoe/homebrew-lectern`. Nothing in the scripts publishes.

## 9. Testing

**Unit tests (Swift Testing)**
- ReaderCore: anchors, history rules, identity matching, policies.
- PDFSave: the parser, the writer, and the pass criteria from §3.2.

**Test PDF regression suite (A6)**
- Every file in the collection must open, render page 1, extract text where it exists, and close cleanly.
- The writer is run on every file that can be annotated.
- The script that generates test files is `scripts/corpus/generate`, and `scripts/corpus/verify` runs the external-reader checks. Committed outputs live in `Tests/Corpus/public/`.
- Private, non-redistributable PDFs go in `Tests/Corpus/private/` (git-ignored) and are used when present.
- *(Amended 2026-10-30, M6)* **As built.**
  - `RegressionSuiteTests` (PDFSave package tests, not sandboxed) lists every PDF under `Tests/Corpus/public/` and fails on one without an entry. Each must:
    - open in PDFKit, with its password if it has one,
    - render page 1 with ink,
    - give text in its first pages, or none on any page for a scan,
    - be released when let go.

    The writer must have a `CorpusCase` for each file.
  - The collection gained four representative documents (spec §9.1):
    - a 475-page text-heavy book, which GovInfo has signed and certified;
    - the 3,270-page PostgreSQL manual;
    - an 1886 scan with no text layer;
    - a 40.8 MB image-heavy NASA report. This one is fetched by `scripts/corpus/bootstrap` into the git-ignored `Tests/Corpus/public/fetched/`, checked by SHA-256, and required by `scripts/test.sh`.
  - `Tests/Corpus/private/` is still unused by the suites.

**User-interface tests (XCUITest)**
- One script per journey in spec §10 (A–D), run against files from the collection.
- *(Amended 2026-10-29, M5)* **Not used.** XCUITest drives real windows on the user's screen, which the user declined. The journeys are covered in-process instead: windows are made transparent and click-through, and the UI tripwire fails any test that tries to show an alert, sheet or panel.

**Accessibility** *(Added 2026-10-29, M5)*
- `AccessibilityAudit` (AppTests) walks a reader window's views, its toolbar, the popovers and every SwiftUI screen (through the accessibility tree). It fails on an interactive element with no name, a control that refuses first responder, a segment with no name, or a toolbar action with no menu equivalent. A test injects an unnamed button and an unreachable one to prove it fails. The selection bar is exempt from focus by design (it must not take focus from the page), and every action on it is in the Annotate menu with a shortcut.
- It checks `refusesFirstResponder` rather than `canBecomeKeyView`, which depends on the Mac's Full Keyboard Access setting.
- **Reduce Motion** turns off the popovers' animation (`Motion` in ReaderKit). Nothing else in the app animates; sidebar and distraction-free changes are immediate.
- **Scanned pages.** The text check (`TextInventory`) runs in the background when a document opens. A document with no text, or some pages without it, says so in the reading view's accessibility help and the pane's value ("No readable text"), so VoiceOver doesn't present scanned pages as readable text.
- **Not verified:** VoiceOver itself, and keyboard focus inside SwiftUI controls (the audit checks their names only).

**The intermittent 5-minute test hang (M3 onwards)** *(Added 2026-10-29, M5)*
- **Cause, from two `sample`s of hung test hosts:** 65 GCD worker threads were parked in `-[NSAnimation _runBlocking]`, which is GCD's thread-pool limit. Each was an `_NSWindowTransformAnimation`: ordering a window out starts one in non-blocking threaded mode, and the test harnesses order hundreds of windows in and out. When those animations don't finish, the pool runs dry and background work never runs. Both hangs were while the display was off (`pmset -g log`: "Display is turned off" at 23:31:10, the hangs at about 00:02 and 00:09 the next day), which fits the hang being intermittent; that link is likely, not proven. One sample had the main thread stuck in `NSDocumentController.recentDocumentURLs` (`NSOperation waitUntilFinished`, as the empty state reappeared); the other had a test waiting forever on the coordinated read of a changed file. Swift Testing's 5-minute limit reported it against whichever M3 or M4 test was running, including `openInSplitCreatesTheSplitAtTheDestination`.
- **Fix:** no window animations in the test host. The test bundle registers `NSAutomaticWindowAnimationsEnabled = NO` in the registration domain (not stored: the host's defaults are the user's), and Lectern's windows and the test harness windows set `animationBehavior = .none` while hosting tests. A temporary probe on `-[NSAnimation startAnimation]` counted 8 such animations in the M5 and sidebar suites before, and none across M3, M5 and the sidebar suites after.
- Also, while hosting tests the app's empty state reads no recent documents and its window is transparent and click-through.
- **The app itself:** an ordered-out window's animation is AppKit's own, and a person can't close 65 windows while the display sleeps, so the app is unchanged.

**Snapshots** *(Added 2026-10-29, M5)*
- `SnapshotTests` render windows offscreen, never ordered on screen, in light and dark: the empty state, a document with the sidebar, the split, the annotation popover, Settings, the shortcut map and distraction-free mode. The sandboxed test host writes them to its temporary folder and `scripts/test.sh` copies them to `build/snapshots/`.
- **How they're made.** A never-ordered window's `cacheDisplay` replays only what views draw themselves: PDFKit's pages come out empty (M0b Q11), and macOS 26's glass and backdrop views draw a white fallback that covers everything in dark mode. So each image is composed: the window background colour, a flat panel where each glass container is, every visible page drawn with `PDFPage.draw(with:to:)` below the toolbar, then `cacheDisplay` of the window with the glass and backdrop views and PDFKit's page views hidden.
- **What's approximate.** Glass is drawn flat, page thumbnails come out blank, and content under the toolbar isn't shown. The tests fail if a reader state shows no page text, or a dark capture is mostly white.
- They found one real bug: a Settings caption that didn't wrap made the form wider than its window.

**Performance**
- XCTest metrics for open time, scroll frame pacing, search time to first result, and thumbnail throughput.
- Thresholds are set on the baseline M1 with 8 GB of memory before release (A6).
- *(Amended 2026-10-30, M6)* **As built:** Swift Testing, not XCTest metrics, in `RepresentativePerformanceTests` (AppTests), run only by `scripts/perf.sh`.
  - **Setup.** perf.sh stages the four representative files into the test host's container with an `enabled` marker (the sandboxed host can't read the repository). It builds the test configuration with `-O` into `build/DerivedData-perf`.
  - **What's measured** (37 measurements in all):
    - open to page 1 drawn;
    - the main thread's cost per scroll step, and the footprint while scrolling;
    - offscreen page drawing (`PDFPage.draw`; real frame pacing needs a screen), and the footprint once every page has been drawn;
    - search: the first result shown, completion, and the longest main-thread gap;
    - thumbnail throughput;
    - the annotation list and ⌘S on the 3,270-page manual.
  - **Pass or fail.** Each measurement has a threshold, and a test fails when one is exceeded. perf.sh fails if fewer than 37 measurements come back.
  - **The thresholds are provisional.** No base M1 with 8 GB was available, so they were set from M3 Pro numbers with headroom and must be re-checked on that machine. The numbers and the reasons for each threshold are in [performance.md](performance.md).

## 10. License

GPL-3.0. See [LICENSE](../LICENSE). Distribution is direct only (B5), so no App Store exception is needed.

## 11. Milestones

| Milestone | Content | Exit criteria |
|-----------|---------|---------------|
| **M0: Prototypes** | (a) Saving: test candidate 1 from §3.2, then 2 if needed. (b) Link preview: hover, Force Click, keyboard focus and the popover in `PDFView`. (c) Active content: what PDFKit does with JavaScript, Launch, GoToR, form submits and field editing. (d) Background thumbnails and progressive search. (e) Whether CI runner images exist. | **Decision point:** §3.2 is settled and every **[verify]** in this doc is resolved or replaced. A failure in (b) or (c) means re-planning the engine, not working around it. |
| **M1: Reader shell** | `NSDocument` with autosave off, tabs and windows, `ReaderPDFView`, the four layouts with cover page and right-to-left (B1), zoom and fit modes, view-only rotation (B9), empty state, recent files, password prompt and permissions (B6), printing | Journey A without saving reading position |
| **M2: Navigation** | Sidebar (outline, thumbnails), go to page, `ReadingAnchor` and keeping your place, history (B2), document identity and stored position (A2), search (B8), reload on change while clean (B7) | Journeys A and D |
| **M3: The signature feature** | Link interception and routing (A4), the preview popover with hover, Force Click and keyboard (A3), split view and focus (B3) | Journey B |
| **M4: Annotations and saving** | Highlight, underline, strike-through, notes, colours, author, undo (B4); the annotation list; the writer from M0; Save a Copy rules (A1); the crash journal; reload with unsaved annotations (B7); read-only forms (A5) | Journey C, including step 6 in other readers |
| **M5: Completion** | Reader bookmarks and JSON export (A2), session restore, Settings, opt-in updates (A4), accessibility pass, keyboard shortcut map, distraction-free mode | Every acceptance criterion in spec §11 except release logistics |
| **M6: Release** | Complete test PDF collection, performance thresholds set and met, signing and notarisation, DMG and cask, installation docs and known limitations | Spec §11 fully met |

*(Amended 2026-10-29, M4b.)* M4 was delivered in two parts: M4a, the save engine (PDFSave), and M4b, everything in the app. Journey C step 6 is checked automatically in PDFKit, MuPDF, Poppler and pdf.js (M4a), and by `qpdf --check` on every file the app tests save. Preview and Acrobat Reader by hand are still open. The author setting's UI moves to M5 with Settings; the `annotationAuthor` user default already works.

*(Amended 2026-10-29, M5.)* Reader bookmarks and their export, session restore, Settings, opt-in updates with Sparkle, the accessibility audit, the shortcut map and distraction-free mode landed in M5. VoiceOver and XCUITest journeys remain unverified (the user declined screen access).

*(Amended 2026-10-30, M6.)* M6 delivered, locally:
- the complete test collection;
- the performance tests, with provisional thresholds, all met on an M3 Pro;
- version 1.0.0 with the licences in the app;
- the DMG, the signed update archive and appcast, and the cask at 1.0.0;
- INSTALL, README, known limitations, the release checklist and the §11 audit ([acceptance.md](acceptance.md)).

**Notarisation is out:** there is no Developer ID (B5). "Spec §11 fully met" depends on three things outside the build:
- making the project public and publishing the release, which are the maintainer's decisions;
- the manual checks in the release checklist;
- performance on the A6 baseline Mac.

Staffing and calendar dates aren't covered here.

## 12. Traceability

Every decision mapped to the component that implements it and the milestone that delivers it.

| Decision | Implemented by | Milestone |
|----------|----------------|-----------|
| A1 Explicit, safe save | `NSDocument` autosave off (§2); PDFSave writer and verification (§3.2); crash journal (§6) | M0 decision, M4 |
| A2 Identity and local state | `DocumentIdentity`, `DocumentState` (§5); Persistence with security-scoped bookmarks (§6); bookmark export | M2, M5 |
| A3 Link preview and keeping your place | ReaderKit link layer and popover (§4.4); `ReadingAnchor` capture and restore (§4.5) | M0 prototype, M2, M3 |
| A4 Active content and network | Link routing table (§4.4); Sparkle opt-in through `UpdateController` (§7); sandbox network entitlement (§6) | M0 check, M3, M5 |
| A5 Forms read-only | Event interception, no `isReadOnly` changes (§4.3); writer leaves forms untouched (§3.2 #4) | M0 check, M4 |
| A6 Platform and test PDFs | Deployment target macOS 26 on Apple Silicon (§1, §8); test PDF collection and performance tests (§9) | M0 onward, M6 |
| B1 Layouts | `ViewSettings`, ReaderKit layout | M1 |
| B2 History | `HistoryStack` per pane (§4.2, §5) | M2 |
| B3 Panes | `NSSplitViewController`, focus tracking, shared `PDFDocument` (§4.2) | M3 |
| B4 Annotations | ReaderKit annotation tools, undo manager, author from Settings (§4.3) | M4 |
| B5 Distribution | Developer ID, notarisation, DMG, cask (§8) | M6 |
| B6 Permissions and passwords | Password prompt, permission checks, Keychain (§6) | M1 |
| B7 Changes on disk | `NSFilePresenter`, original bytes kept in memory (§4.2) | M2 (clean), M4 (with unsaved annotations) |
| B8 Search | PDFKit asynchronous find, sidebar results list (§4.6) | M2 |
| B9 Rotation | View-only rotation that is never serialised: the writer only writes annotation objects, and Save a Copy builds a fresh document from the original bytes (§4.3) | M1 |

## 13. Open items

1. ~~**The save path (§3.2).**~~ Decided in M0a: our own incremental writer.
2. **Every [verify] item.** Resolved by M0.
3. ~~**Apple Developer Program membership**~~ Decided: none for v1. Unsigned (ad-hoc) distribution with documented install steps (§8).
4. ~~**Product name and bundle ID.**~~ Decided 2026-10-30: Lectern, `io.github.ronimoe.Lectern`, which is what M1 already used.
