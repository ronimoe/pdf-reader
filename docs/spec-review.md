# Spec Review: Product Specification v1.0

Review of "Product Specification — Open-Source PDF Reader for macOS, v1.0".

**Overall:** The vision, non-goals and decision rules are strong and unusually disciplined. Most of the problems are in the parts that will be hardest to build: saving, local state, the link-preview feature, and how the app treats untrusted PDF content. The spec also says nothing about several of these, and they need product answers before architecture work starts.

Decided outside the spec: **License = GPL-3.0** (see item B5 for a distribution consequence).

**Status (2026-10-28):** A1–A6 and B5 are resolved, and the answers are recorded in [decisions.md](decisions.md). B1–B4, B6–B9 and the C items remain open.

---

## A. Blockers: resolve before technical design

### A1. The save model is undefined, and it is the riskiest part of v1
§5.3, §8 Rule 7, §9.2 require safe, predictable saving that never alters unrelated content. The spec doesn't say:

- **When a save happens.** It could be explicit ⌘S only, macOS autosave, or Save As only. macOS document apps autosave by default, which would conflict with "ordinary reading should never change the original file" unless annotation edits are clearly separated from reading.
- **How the file is written.** A full rewrite of the PDF can drop or alter content: digital signatures, incremental-update history, some structure trees, XFA, unusual object types. An *incremental update* appends changes and leaves the original bytes intact. **PDFKit, the obvious engine, rewrites the whole file on save**, so "no silent alteration" may not be achievable with it alone. This needs a spike before the engine is chosen.
- **Which documents are "unsafe to save"** (§5.3 mentions this but doesn't define it). Candidates: signed documents (saving invalidates signatures), encrypted documents (keep encryption? which password?), documents whose permissions forbid annotation, files on read-only volumes, and documents that fail a post-save verification.
- **What happens to unsaved annotations after a crash.** Rule 7 implies they must survive, but the spec doesn't require recovery.

**Proposed addition:** "Annotations are saved only on an explicit Save. The original bytes are preserved through an incremental update where possible. Signed, permission-restricted or otherwise unsafe documents offer Save As a copy. Unsaved annotations are journaled locally and recovered after a crash."

### A2. Local state has no defined home or document identity
Reading positions, bookmarks, recents and session restore (§5.2, §5.4) all need to recognise "the same document". The spec doesn't define what that means:

- When a file is **moved or renamed**, does the reading position follow it? (Path-based keys break.)
- When a file is **duplicated**, do both copies share a position?
- When a file is **replaced by a newer version** (a re-downloaded paper, a recompiled LaTeX output), is it the same document?

**Bookmarks** are the sharpest case. The PDF standard has no "reader bookmark", so either:
- (a) they live in local app storage and don't travel with the file, which is a mild form of the lock-in that Goal 5 forbids unless they can be exported, or
- (b) they are written into the PDF as outline entries or annotations, which modifies the document.

The spec should choose, and Rule 5 points to (a) plus export.

### A3. "Never Lose Your Place" needs a precise definition
This is the signature feature (§2 Goal 2, Journey B), but it is underspecified:

- **Trigger.** "Activates the reference preview action" isn't defined. Hover alone is ruled out by Rule 8 and §4.4, so there must be a keyboard path. PDF links aren't keyboard-focusable by default, so the app needs a way to cycle through links on a page.
- **What the preview shows.** Many destinations are `/Fit` (a whole page) or `/XYZ` with a null top, so "show the figure" isn't always possible. Specify a fallback, such as the full page scaled, with the target region marked when it is known.
- **Supported link types.** Explicit destinations, named destinations, `GoTo` actions: yes. `GoToR` (other file), `URI` and `Launch`: specify, probably no.
- **Chained previews.** Can you follow a link *inside* a preview? Does that add history?
- **The "place" itself.** The spec covers link following but not the more common ways readers lose their place: **zooming, window resizing, switching single/two-page layout, rotating, and reloading a changed file** should all keep the same anchor visible. Add this explicitly, because it is cheap to specify and expensive to retrofit.

### A4. How to treat active and untrusted PDF content
Rule 6 says reading must not cause network activity, but PDFs can carry:

- external `URI` links,
- `Launch` actions,
- JavaScript,
- embedded files,
- form submit actions,
- remote `GoToR` targets.

**Proposed rule:** "JavaScript is never executed. Launch and submit actions are never performed. External links open only on an explicit click, after the full URL is shown. Embedded files are listed but never opened automatically."

The spec also needs a network policy for the app itself:
- **Update checks** (for example Sparkle) are network activity. Make them opt-in or ask on first launch.
- **Crash reporting.** "No mandatory telemetry" implies opt-in is allowed. Say so, or rule it out entirely.

### A5. Forms are excluded, but documents with forms will be opened
§7 excludes form filling, but many ordinary PDFs contain form fields with values. Decide:

- Are fields shown with their values? (They should be.)
- Can the user type into them? (They should not, or every keystroke becomes an unsaved modification.)
- Does saving annotations preserve existing form data byte-for-byte?

### A6. The acceptance criteria aren't yet testable
§9.1 and §11 rely on "feel fast", "representative documents" and "reliably". The spec intentionally defers the numbers, but two inputs are needed **now**, because they shape the architecture:

- **Minimum macOS version and hardware floor.** These aren't stated, and they decide which native APIs are available.
- **A named test corpus**, committed to the repo, covering:
  - a 1,000+ page text book,
  - an image-heavy report,
  - scanned pages with no text layer,
  - mixed page sizes and orientations,
  - an academic paper with named destinations,
  - AES-256 encrypted, signed and permission-restricted files,
  - a form-bearing PDF,
  - a tagged/accessible PDF,
  - a PDF with existing third-party annotations,
  - deliberately malformed or truncated files.

Each user journey in §10 should map to scripted checks against this corpus.

---

## B. Should clarify before or during design

### B1. Reading layouts are ambiguous
Goal 1 lists "single-page, continuous-scroll, two-page". §5.1 lists continuous scroll plus single and two-page layouts. Decide which of the four combinations ship: single paged, single continuous, two-up paged, two-up continuous. Also missing:

- **Cover page handling** (book mode, where page 1 is shown alone).
- **Right-to-left reading order** (the PDF `/Direction /R2L` viewer preference).
- **Spreads with mixed page sizes.**

### B2. History semantics
§5.2 calls for back/forward history but doesn't say what creates an entry. Proposal:

- **Creates an entry:** link follows, outline and thumbnail jumps, go-to-page, search-result jumps, and bookmark jumps.
- **Doesn't create an entry:** scrolling.

Also decide:
- Is history per pane in split view, or per document?
- Does it survive closing and reopening the document?

### B3. Split view, tabs and windows interact in unspecified ways
The spec allows three ways to see more than one view: tabs, windows and split view. Define:

- Which pane receives search results and outline clicks.
- Whether a preview's "open in separate pane" (Journey B) reuses an existing split.
- How session restoration handles splits.
- What happens when an already-open file is opened again. The Mac convention is to focus the existing window.

### B4. Annotation details
- **"Text notes"** could mean a standalone sticky note (a `Text` annotation), a comment attached to a highlight (the markup's `Contents`/popup), or both. They behave differently in other readers, and Journey C step 6 depends on that.
- **"Edit and remove annotations created by the user."** After save and reopen, the app can't tell who created an annotation except by its author field. Decide whether users may edit or delete *any* annotation or only their own.
- **Author name is a privacy issue.** By default the macOS user's full name gets written into every annotation's `/T` field and travels with the shared PDF. Make it a visible setting, possibly empty by default.
- **Undo/redo** for annotation actions isn't mentioned. It is essential for "predictable editing" on the Mac.
- **Annotation colours.** Rule 8 means colour can't be the only distinguishing feature. Highlight, underline and strike-through are already distinct shapes, so only colour-coded meanings need care.

### B5. GPL-3.0 and the Mac App Store
GPL-3.0 is widely considered incompatible with App Store terms (the 2011 VLC removal is the usual reference). If App Store distribution is ever wanted, one of these must be set up **before the first outside contribution**:

- an explicit App Store exception added to the license, or
- a contributor agreement that allows relicensing.

If distribution is direct download only (a notarised DMG or Homebrew cask), no action is needed. Record the decision either way.

### B6. Document permissions and passwords
- §5.1 says "copy selectable text where permitted" but doesn't mention print or annotate permissions. Apply one rule to all owner-password permissions.
- Session restoration (§5.4) must say whether passwords are **ever** persisted. Recommendation: never by default, with optional Keychain storage per document.

### B7. Files that change on disk
This is very common for the technical audience (LaTeX preview loops, re-downloaded papers) and not mentioned. Proposal:

- Detect the change and offer a reload, or reload automatically when there are no unsaved annotations.
- Preserve the reading anchor across the reload.
- If there are unsaved annotations, warn the user and offer Save As.

### B8. Search behaviour
Specify:

- Case and diacritic sensitivity, and whether there is a whole-word option.
- Whether results stream in while a long document is still being searched (§9.1 implies yes).
- Whether annotation text is searched.
- What scanned documents show. They should say clearly "this document has no searchable text" rather than "no results", which ties to §9.3.

### B9. Rotation persistence
"Rotate the viewing orientation" suggests that rotation is view-only and never written to the file. Confirm this, and say whether it is remembered per document locally.

---

## C. Minor

- **Product name.** Needed before the bundle ID, repository name and any distribution channel. It doesn't block design.
- **Dark mode with white pages.** Rule 4 is the right call, but bright pages in a dark UI are the most common complaint about readers that make this choice. List it under "known limitations" (§11) so it reads as deliberate.
- **Thumbnails.** Generating thumbnails for long documents must be lazy and must not block the UI. This is already covered by §9.1's spirit and is worth a line in Goal 2.
- **§3 mentions citations.** Make sure "citations" doesn't drift toward reference parsing, which §7 explicitly defers.

---

## Suggested next step
Answer A1–A6 (a sentence or two each is enough), then fold the answers and the B items into spec v1.1. A1 and A3 should each get a short prototype spike before the PDF engine is chosen, because they decide whether PDFKit alone is viable.
