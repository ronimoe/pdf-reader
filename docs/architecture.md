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

The M0a prototype passed every applicable pass criterion on the whole generated test collection. Full results are in [spikes/m0a-save.md](spikes/m0a-save.md). Encrypted files are refused with `PDFSaveError.encrypted`. In v1, annotations can't be saved into encrypted files at all (see §4.3).

*(Amended 2026-10-29, M4a.)* `Saveability.evaluate` reports one of three outcomes:
- `inPlace`,
- `copyOnly`, for signed, certified (DocMDP) and Reader-extended (UR3) files, and files in a read-only location,
- `unsupported`, for encrypted or malformed files.

Copy-only files are saved with `saveCopy`, which is the original bytes plus the appended update, written to a new file. The production API is described in [spikes/m4a-save-engine.md](spikes/m4a-save-engine.md).

**Open work for production (M4)**
- Map each `PDFAnnotation` to its object in the file. Our own annotations are matched by `/NM`; third-party ones by page and `/Rect`.
- Fuzz the parser.
- Test the writer on real-world files: linearized, certified (DocMDP) and Reader-extended (`/Perms /UR3`).

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

**How M3 builds the split** *(Amended 2026-10-29, M3)*
- **Layout.** The reading area holds a nested, vertical `NSSplitViewController` with one `PaneContainerView` per pane. A container holds the `ReaderPDFView`, a 3 pt focus bar along the top of the focused pane's safe area (shape as well as colour), a close button, and the link status line. A second pane is created at equal width.
- **Focus.** The focused pane follows the window's first responder (KVO). Outline, thumbnails, Go to Page, search, zoom and Back/Forward act on it. A search keeps acting on the pane it started in until it ends.
- **Layout, rotation and reload** apply to every pane inside every pane's anchor capture. Each pane keeps its own zoom mode, and `ViewSettings.zoom` stores the last zoom chosen.
- **Closing.** Either pane can close. Closing the first pane moves the second pane's place, zoom and history into it, so the pane that stays is always `.primary`.
- **Open in Split** from a preview creates the split at the destination with an empty history; focus stays on the reader's pane. If the tab is already split, the other pane jumps there and records it in its own history.
- **Stored state.** `DocumentState.split` (`SplitState`: the second pane's anchor and the focused pane) is stored with the second pane's history under `PaneID.secondary`. `anchor` stays the first pane's place. Older state decodes with no split.
- **Assigning a document.** Always through `ReaderPDFView.show(_:)`, never by setting `document`. This follows main's crash fix: PDFKit reads `document` from background queues.
  - The view also re-attaches its clip-view observer on every `layout()` and `restore`, because PDFKit can replace its scroll view after a document change. Without that, a later `layoutDocumentView()` moved the reader by about 25 pt and nothing put them back (found while restoring a split).

### 4.3 Rule: what's on screen must never leak into a saved file

PDFKit's obvious ways to rotate a page, lock a form field or set an annotation's author all change the `PDFDocument` itself. So:

- **Rotation (B9)** is applied with `PDFPage.rotation` in the shared model, because PDFKit offers no separate per-view rotation [verify]. The original value of every page is recorded when the document opens.
  - *(Amended 2026-10-29, M1)* For an encrypted document, "opens" means the moment it is first unlocked, because the pages aren't readable before then. `ReaderDocument.originalPageRotations` and `originalRotation(ofPageAt:)` give the save path these values.
  - The view rotation is applied as `original + ViewSettings.rotation` on every page.
  - Printing uses the on-screen model, so a rotated view prints rotated, as in Preview.
- **Form fields (A5)** stay non-editable because `ReaderPDFView` catches mouse and keyboard events aimed at them. Their `isReadOnly` flag is never set. Prototype check [verify]: whether keyboard focus can still reach a field.
- **The author (B4)** is set only on new annotations, from Settings, where the default is empty.
  - PDFKit fills in `/T` (the Mac account's full name) and `/M` (a date) on every new annotation, including its popup, on its own *(Amended 2026-10-29, M0b Q5)*.
  - Clear both explicitly, and set them only from Settings. The incremental writer serialises only what we give it, so it is the final guard.

**What gets written**
- The **incremental writer** writes only the objects the app chose to create or change: annotation objects, plus the annotation lists of the pages involved. Changed rotation therefore can't reach the file.
- **Save a Copy is the original bytes plus the incremental writer's appended section, written to a new file.** PDFKit's own `write(to:)` and `dataRepresentation()` are never used to save *(Amended 2026-10-29, M0b Q6)*. They rewrite the whole file, which:
  - drops page labels, `/ID`, custom metadata and the revision history,
  - separates form fields from their widgets, so `qpdf` warns on every widget, which breaks A5.

  The only case where the incremental writer can't produce the copy is an encrypted document (`PDFSaveError.encrypted`). Saving annotations into encrypted documents isn't supported in v1. The app explains this and saves nothing.

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
  - Everything else goes to the window. `http` and `https` go to the `URLOpening` seam. Other schemes get a confirmation sheet that shows the URL. `GoToR`, `Launch`, `SubmitForm`, `JavaScript` and any other type get an explanation sheet (`BlockedLink`).
  - While hosting tests, the default opener only records.
- **Hover.** A `Timer` in the common run-loop modes, rather than a dispatch delay. A hover preview closes 0.4 s after the pointer leaves the link, unless the pointer went into the preview.
  - The link under the pointer, or the focused link, is shown in a status line at the bottom of the pane: the full URL for web and other-scheme links.
  - "Preview Links on Hover" (View menu) is stored in `UserDefaults` under `PreviewLinksOnHover` and defaults to on. Tests use in-memory preferences.
- **Force Click.** Stage 2 in `pressureChange` previews an internal link, and the release then doesn't follow it. `quickLook(with:)` over a link previews too.
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

**Saving**
- Serialising and verifying run off the main thread, from a snapshot of the annotation state.
- The swap into place happens on the main thread through `NSDocument`'s safe-save.

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
| `LinkTarget` | ReaderKit | A link's destination or action, classified for routing (§4.4) |

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

**Other storage**
- **Recent documents:** the system recents list kept by `NSDocumentController`.
- **Session restore:** AppKit window restoration, which brings back windows, tabs, splits and each pane's anchor (B3).
- **Settings:** `UserDefaults`.
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

## 8. Build and distribution

**Project setup** *(Amended 2026-10-29)*
- The Xcode project is generated by **XcodeGen** (MIT, developer tool) from `project.yml` and isn't committed. Hand-editing `project.pbxproj` is error-prone for agents and for contributors, and a text spec merges cleanly.
- All library code lives in one local package, `Packages/LecternKit`, with five targets: ReaderCore, PDFSave, Persistence, ReaderKit and ReaderUI.
- `scripts/test.sh` regenerates the project and runs `swift test` and `xcodebuild test` headlessly.
- Builds are signed ad-hoc (`CODE_SIGN_IDENTITY=-`) with the hardened runtime on, because there's no Developer ID yet.

**Continuous integration** *(Amended 2026-10-29)*
- **Local is the gate.** `scripts/test.sh` is the merge gate, run on a developer Mac.
- **No hosted runner fits.** No GitHub-hosted runner has macOS 26 with Xcode 27. The `xcode-27` preview image runs macOS 27, and `macos-26` has Xcode 26.6 at most.
- **If CI is added later,** it targets `xcode-27` and runs only on manual trigger (`workflow_dispatch`): the repo is private and macOS runner minutes are expensive.

**Release (B5)** *(Amended 2026-10-29: no Developer ID)*
1. Archive a Release build: `xcodebuild archive`, signed ad-hoc with the hardened runtime on and no `get-task-allow`.
2. Package the DMG and publish it on GitHub Releases.
3. Sign the update archive with Sparkle's EdDSA key. The private key is kept off the repo and backed up offline.
4. Publish a Homebrew cask in our own tap, `ronimoe/lectern`.
   - The cask removes the download quarantine after installing, through `postflight`. The official `homebrew/cask` rejects apps that fail Gatekeeper, so it can't host this app.
   - *(Amended 2026-10-29, M6a)* It leaves `auto_updates` unset: the in-app updater is opt-in and off by default, so `brew upgrade` must handle upgrades.
5. **User install instructions** are in `docs/INSTALL.md`, written in M6:
   - Homebrew from the tap,
   - the DMG with System Settings → Privacy & Security → **Open Anyway**,
   - building from source.

   The Control-click → Open bypass no longer exists on macOS 15 and later.

## 9. Testing

**Unit tests (Swift Testing)**
- ReaderCore: anchors, history rules, identity matching, policies.
- PDFSave: the parser, the writer, and the pass criteria from §3.2.

**Test PDF regression suite (A6)**
- Every file in the collection must open, render page 1, extract text where it exists, and close cleanly.
- The writer is run on every file that can be annotated.
- The script that generates test files is `scripts/corpus/generate`, and `scripts/corpus/verify` runs the external-reader checks. Committed outputs live in `Tests/Corpus/public/`.
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

1. ~~**The save path (§3.2).**~~ Decided in M0a: our own incremental writer.
2. **Every [verify] item.** Resolved by M0.
3. ~~**Apple Developer Program membership**~~ Decided: none for v1. Unsigned (ad-hoc) distribution with documented install steps (§8).
4. **Product name and bundle ID.** Needed before M1 settles the storage paths. A placeholder works until then.
