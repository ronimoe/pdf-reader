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
- **Search.** Whether `beginFindString` returns results progressively (B8) without blocking the main thread.

### 3.2 Saving annotations: **open, decided by the A1 prototype**

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
- Both panes share the same `PDFDocument`, so an annotation added in one appears in the other at once.

**Focus (B3)**
- The tab tracks which pane is focused.
- The sidebar and search act on that pane.

**Changes on disk (B7)**
- The document watches its file through `NSFilePresenter` (or `NSDocument`'s built-in handling).
- It applies B7's rules: reload silently when there are no unsaved annotations; otherwise ask.

### 4.3 Rule: what's on screen must never leak into a saved file

PDFKit's obvious ways to rotate a page, lock a form field or set an annotation's author all change the `PDFDocument` itself. So:

- **Rotation (B9)** is applied with `PDFPage.rotation` in the shared model, because PDFKit offers no separate per-view rotation [verify]. The original value of every page is recorded when the document opens.
- **Form fields (A5)** stay non-editable because `ReaderPDFView` catches mouse and keyboard events aimed at them. Their `isReadOnly` flag is never set. Prototype check [verify]: whether keyboard focus can still reach a field.
- **The author (B4)** is set only on new annotations, from Settings, where the default is empty.

**What gets written**
- The **incremental writer** writes only the objects the app chose to create or change: annotation objects, plus the annotation lists of the pages involved. Changed rotation therefore can't reach the file.
- **Save a Copy** and the fallback path build a **fresh `PDFDocument` from the original bytes**, then copy across only the annotations the user created, edited or deleted. They never write the on-screen model directly.

### 4.4 Link interception and preview (A3, A4)

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

### 4.5 Keeping your place

A `ReadingAnchor` records a page index plus a point in that page's coordinates, plus the zoom.

The pane captures the anchor before any of these, and restores it afterwards:
- zooming,
- resizing,
- changing layout (B1),
- rotating (B9),
- reloading (B7).

The same type is stored as the reading position (A2) and used for history entries (B2).

### 4.6 Concurrency

**Main thread:** all UI, and the `PDFDocument` shared by the panes.

**Search (B8):** uses PDFKit's asynchronous find, whose results arrive through delegate callbacks.

**Thumbnails**
- Generated lazily by a background actor.
- The actor opens its own `PDFDocument` from the same bytes.
- Results are cached in memory, keyed by page index and the size and scale they were drawn at.

**Saving**
- Serialising and verifying run off the main thread, from a snapshot of the annotation state.
- The swap into place happens on the main thread through `NSDocument`'s safe-save.

## 5. Internal data structures

| Type | Module | Purpose |
|------|--------|---------|
| `ReadingAnchor` | ReaderCore | `pageIndex`, `pointInPage`, `scale`. Used for keeping your place, the stored position, and history entries |
| `HistoryStack` | ReaderCore | Back and forward lists of `ReadingAnchor`, one per pane. A search session adds one entry (B2) |
| `DocumentIdentity` | ReaderCore | File bookmark data, the PDF's internal `/ID` pair, page count, file size, last known path (A2) |
| `ViewSettings` | ReaderCore | Pages, Scrolling, cover-page and right-to-left overrides (B1), rotation (B9), zoom mode, sidebar section |
| `DocumentState` | Persistence | Identity, last anchor, per-pane history, reader bookmarks, view settings. Written to disk as JSON |
| `AnnotationChange` | PDFSave | Add, edit or delete of one annotation, with its full properties. Feeds the crash journal and the writer |
| `LinkTarget` | ReaderKit | A link's destination or action, classified for routing (§4.4) |

## 6. Storage

**Per-document state (A2)**
- One JSON file per document, at `~/Library/Application Support/<bundle-id>/Documents/<uuid>.json`.
- Files are written atomically, and only after a debounce interval.
- **Why JSON:** a person can read it, it's trivial to export (A2's bookmark export), and the volume is small. There's no need for SQLite or SwiftData.
- **Identity index:** `index.json` maps document identities to UUIDs.

**Crash journal (A1)**
- `Journal/<uuid>.json` holds the unsaved `AnnotationChange` list.
- It's rewritten after every change (debounced), and deleted after a successful save or an explicit discard.
- When the document next opens, the app offers to restore it.

**Other storage**
- **Recent documents:** the system recents list kept by `NSDocumentController`.
- **Session restore:** AppKit window restoration, which brings back windows, tabs, splits and each pane's anchor (B3).
- **Settings:** `UserDefaults`.
- **Passwords:** Keychain, only when "Remember in Keychain" is ticked (B6).

**Sandbox: on.** The App Sandbox is optional for direct DMG distribution, but turning it on limits the damage a hostile PDF could do through the rendering engine. It means:

| Entitlement or setting | Why |
|------------------------|-----|
| Read-write access to files the user chooses | Opening and saving documents |
| Security-scoped file bookmarks | `DocumentIdentity`, so state survives restarts (A2) |
| Outgoing network connections | Only so the opt-in update checks can work (A4) |

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

## 8. Build and distribution

**Project setup**
- An Xcode project using folder-synchronised groups, which keep the project file small, plus local Swift packages.
- No project generator.

**Continuous integration**
- GitHub Actions on macOS runners, running `xcodebuild test` and the test-PDF regression suite.
- **[verify]** whether hosted runners have macOS 26 and Xcode 27 images. If not, use a self-hosted runner.

**Release (B5)**
1. `xcodebuild archive`.
2. Sign with a Developer ID certificate, with the hardened runtime on.
3. Notarise with `notarytool`, then staple the ticket to the app.
4. Package as a DMG and publish it on GitHub Releases.
5. Publish a Homebrew cask, first in our own tap and later in `homebrew/cask` once the app qualifies.

**Open item for you:** signing and notarisation need a paid **Apple Developer Program membership**. Without it, users have to bypass Gatekeeper by hand, which goes against "no friction" in Journey A. Who holds the membership, and in whose name, is your decision.

## 9. Testing

**Unit tests (Swift Testing)**
- ReaderCore: anchors, history rules, identity matching, policies.
- PDFSave: the parser, the writer, and the pass criteria from §3.2.

**Test PDF regression suite (A6)**
- Every file in the collection must open, render page 1, extract text where it exists, and close cleanly.
- The writer is run on every file that can be annotated.
- The script that generates test files lives in `Tests/Corpus/generate`.
- Private, non-redistributable PDFs go in `Tests/Corpus/private/` (git-ignored) and are used when present.

**User-interface tests (XCUITest)**
- One script per journey in spec §10 (A–D), run against files from the collection.

**Performance**
- XCTest metrics for open time, scroll frame pacing, search time to first result, and thumbnail throughput.
- Thresholds are set on the baseline M1 with 8 GB of memory before release (A6).

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

Staffing and calendar dates aren't covered here.

## 12. Traceability

Every decision mapped to the component that implements it and the milestone that delivers it.

| Decision | Implemented by | Milestone |
|----------|----------------|-----------|
| A1 Explicit, safe save | `NSDocument` autosave off (§2); PDFSave writer and verification (§3.2); crash journal (§6) | M0 decision, M4 |
| A2 Identity and local state | `DocumentIdentity`, `DocumentState` (§5); Persistence with security-scoped bookmarks (§6); bookmark export | M2, M5 |
| A3 Link preview and keeping your place | ReaderKit link layer and popover (§4.4); `ReadingAnchor` capture and restore (§4.5) | M0 prototype, M2, M3 |
| A4 Active content and network | Link routing table (§4.4); Sparkle opt-in; sandbox network entitlement (§6) | M0 check, M3, M5 |
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

1. **The save path (§3.2).** Decided by M0.
2. **Every [verify] item.** Resolved by M0.
3. **Apple Developer Program membership** (§8). Your decision.
4. **Product name and bundle ID.** Needed before M1 settles the storage paths. A placeholder works until then.
