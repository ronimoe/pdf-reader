# Product Decisions

Answers to the open items in [spec-review.md](spec-review.md). Each one amends or clarifies [product-spec.md](product-spec.md) v1.0, and they will be folded into spec v1.1.

| ID | Topic | Decided |
|----|-------|---------|
| A1 | Saving annotations | 2026-10-28 |
| A2 | Document identity and local state | 2026-10-28 |
| A3 | Link preview and keeping your place | 2026-10-28 |
| A4 | Active content and network use | 2026-10-28 |
| A5 | Existing form fields | 2026-10-28 |
| A6 | Platform floor and test corpus | 2026-10-28 |
| B5 | Distribution channels | 2026-10-28 |
| — | License: GPL-3.0 | 2026-10-28 |

---

## A1. Saving annotations

- **Explicit save only.** Annotation changes are written to the PDF only when the user saves (⌘S). The app never autosaves into the PDF, and reading alone never writes to the file.
- **Original bytes are preserved.** A save appends an incremental update to the file and does not rewrite it, so all of the original content survives unchanged.
- **Unsafe documents get Save a Copy.** Signed documents, documents whose permissions forbid annotation, files on read-only locations, and any save that fails post-write verification are never modified in place. The app explains why and offers Save a Copy.
- **Crash recovery.** Annotations that haven't been saved are journaled locally. After a crash, the next time the document opens the app offers to restore them.
- **Consequence for the engine choice.** As far as known, PDFKit's built-in save rewrites the whole file. Before the PDF engine is chosen, a spike must confirm whether incremental-update saving can be done, either on top of PDFKit or with a separate writer.

## A2. Document identity and local state

- **Where state lives.** Reading positions, reader bookmarks, history, recent documents and per-document view settings are stored locally on this Mac. They are never written into the PDF.
- **How a document is recognised:**
  - **Primary:** a macOS file bookmark, which follows renames and moves.
  - **Fallback:** the PDF's internal `/ID`, when the file bookmark no longer resolves.
- **A modified file at the same path** is treated as the same document. Positions and bookmarks are remapped by page number and clamped to the new page count.
- **A duplicated file** with the same `/ID` starts with the original's state and diverges from then on.
- **Export.** Reader bookmarks can be exported as JSON, so they aren't locked in (Goal 5, Rule 5).

## A3. Link preview and keeping your place

**Following a link**
- Clicking an internal link jumps to its destination and creates a back/forward history entry.

**Opening a preview.** All three methods open the same preview popover:
- **Hover:** pointing at the link for about 0.5 seconds. Hover preview can be turned off in settings.
- **Force Click:** a firm press on a Force Touch trackpad.
- **Keyboard:** a dedicated shortcut. The user can also cycle focus through the links on the visible page and preview the focused one (Rule 8).

**What the preview shows**
- If the destination has coordinates, the preview shows that region with the target marked.
- For `/Fit` destinations, or destinations without a usable position, it shows the whole page scaled to fit.

**Preview actions**
- **Go:** navigates to the destination and records a history entry.
- **Open in Split:** shows the destination in a second pane.
- **Dismiss:** closes the preview. Escape also dismisses it.

**Supported destinations.** Explicit destinations, named destinations and `GoTo` actions. The other link types are covered by A4.

**Keeping your place is a requirement.** Zooming, resizing the window, switching layout, rotating, and reloading a file that changed on disk must all keep the user's current reading anchor in view.

## A4. Active content and network use

**PDF content**
- **JavaScript** is never executed.
- **`Launch` actions, form submit actions and `GoToR` (links to other files)** are never performed. The app explains this when the user activates one.
- **External `http`/`https` links** show their full URL and open in the default browser only when clicked.
- **Links with any other scheme** ask for confirmation first.
- **Embedded files** are listed and can be saved with an explicit action. They are never opened automatically.

**The app's own network use**
- **Updates:** on first launch the app asks once whether to check for updates automatically. The choice can be changed in settings.
- **No telemetry:** the app has no crash reporter, analytics or telemetry of any kind.

## A5. Existing form fields

- Form fields and their stored values are displayed exactly as they are in the file.
- Fields are read-only. A quiet info line tells the user that form filling isn't supported in this version.
- Saving annotations leaves form data byte-for-byte unchanged, which follows from A1.

## A6. Platform floor and test corpus

**Platform and performance baseline**
- **Minimum system:** macOS 26 (Tahoe) or later, on Apple Silicon only.
- **Performance baseline:** the base M1 Mac with 8 GB of memory. Numeric thresholds (§9.1) are measured on this machine before release.

**Test corpus.** The repository contains only redistributable material:
- public-domain PDFs,
- CC-licensed PDFs,
- arXiv papers under permissive licenses,
- PDFs generated by a script for the encrypted, signed, permission-restricted, malformed and mixed-page-size cases.

Real-world PDFs that can't be redistributed go in a git-ignored local folder. Tests use that folder if it exists.

**Coverage.** The corpus covers every category listed in spec-review.md A6. Each user journey in spec §10 maps to scripted checks against it.

## B5. Distribution channels

- **Channels:** a notarised DMG published on GitHub Releases, and a Homebrew cask.
- **Not distributed through the Mac App Store.** Because of that, GPL-3.0 needs no App Store exception and no contributor agreement.
- **If the App Store is reconsidered later,** an exception requires agreement from every copyright holder at that time.

---

## Still open

These spec-review items have not been decided yet:

- **B1:** which reading layouts ship, cover-page handling, and right-to-left reading order.
- **B2:** what creates a back/forward history entry.
- **B3:** how split view, tabs and windows interact.
- **B4:** annotation details: what a text note is, who can edit which annotations, the author-name setting, undo, and colours.
- **B6:** document permissions and whether passwords are ever stored.
- **B7:** files that change on disk while open.
- **B8:** search behaviour.
- **B9:** whether rotation is remembered.
- **C:** the minor items, including the product name.
