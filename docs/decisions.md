# Product Decisions

Answers to the open items in [spec-review.md](spec-review.md). Each one amends or clarifies [product-spec.md](product-spec.md) v1.0, and they will be folded into spec v1.1. [architecture.md](architecture.md) shows where each decision is implemented.

| ID | Topic | Decided |
|----|-------|---------|
| A1 | Saving annotations | 2026-10-28 |
| A2 | Document identity and local state | 2026-10-28 |
| A3 | Link preview and keeping your place | 2026-10-28 |
| A4 | Active content and network use | 2026-10-28 |
| A5 | Existing form fields | 2026-10-28 |
| A6 | Platform floor and test corpus | 2026-10-28 |
| B1 | Reading layouts | 2026-10-29 |
| B2 | Back/forward history | 2026-10-29 |
| B3 | Split view, tabs and windows | 2026-10-29 |
| B4 | Annotation details | 2026-10-29 |
| B5 | Distribution channels | 2026-10-28 |
| B6 | Permissions and passwords | 2026-10-29 (amended 2026-10-30: annotating encrypted files) |
| B7 | Files that change on disk | 2026-10-29 |
| B8 | Search behaviour | 2026-10-29 |
| B9 | Rotation | 2026-10-29 |
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

## B1. Reading layouts

**Two independent toggles**
- **Pages:** Single or Two-up.
- **Scrolling:** Continuous or Paged.

Together they give all four combinations.

**Two-up details**
- **Cover page.** "Cover page alone" follows the PDF's `/PageLayout` hint (`TwoPageRight`/`TwoColumnRight`), and the user can override it per document.
- **Spread order.** Spreads read right-to-left when the PDF sets the `/Direction /R2L` viewer preference. The user can override it per document.
- **Mixed page sizes.** Pages of different sizes are centred within the spread and keep their true relative size.

## B2. Back/forward history

**What adds an entry.** Each of these jumps adds one:
- following a link,
- outline, thumbnail, bookmark and annotation-list jumps,
- go-to-page,
- the preview's Go action.

**What doesn't**
- **Scrolling** never adds an entry.
- **Searching** adds one entry per search session: the position just before searching started. Stepping through results adds nothing more, so Back returns to where the user was before searching.

**Scope and lifetime**
- **Per pane:** each split pane keeps its own history.
- **Persistent:** history is saved locally per document, so it survives closing and reopening.

## B3. Split view, tabs and windows

**The split**
- One document shown in two equal panes inside the same tab.
- The focused pane has a clear indicator.
- The sidebar (outline, thumbnails, bookmarks, annotations) and search act on the focused pane.

**Open in Split** (from a link preview)
- If the tab isn't split yet, the split is created.
- If it is, the other pane navigates to the destination and records that move in its own history.

**Tabs and windows**
- **Already-open files.** Opening a file that's already open brings its existing tab forward. Two views of the same document come from the split, not from duplicate tabs.
- **Session restore** brings back windows, tabs, splits and each pane's position.

## B4. Annotation details

**Notes come in two forms**
- **Standalone sticky notes:** a PDF `Text` annotation.
- **Comments on markup:** a comment attached to a highlight, underline or strike-through, stored in that annotation's `Contents` and popup.

**Editing**
- **Who can edit what.** The user can edit or delete any annotation, including ones made by other people or other apps.
- **Undo and redo.** Every annotation action can be undone and redone until the document is closed. This includes actions that have already been saved, where undoing creates a new unsaved change.

**Author name**
- Empty by default. It is never filled in automatically from the macOS account.
- The user can set it in Settings, and it is then written into each new annotation's `/T` field.

**Colours**
- Six preset colours, with yellow as the default highlight.
- Highlight, underline and strike-through are told apart by shape, not colour (Rule 8).
- Each colour has a name for VoiceOver.

## B5. Distribution channels

- **Channels:** a DMG published on GitHub Releases, and a Homebrew cask in our own tap.
- **Signing** *(Amended 2026-10-29: no Developer ID for v1)*: the app is signed ad-hoc and isn't notarised. A downloaded DMG must be allowed once in System Settings → Privacy & Security → Open Anyway. The tap's cask removes the quarantine itself. Sparkle updates arrive without quarantine, so the step isn't repeated on each release.
- **Not distributed through the Mac App Store.** Because of that, GPL-3.0 needs no App Store exception and no contributor agreement.
- **If the App Store is reconsidered later,** an exception requires agreement from every copyright holder at that time.

## B6. Permissions and passwords

**Permissions**
- The app respects owner-password restrictions on copying, printing and annotating.
- A blocked action is never silently ignored. The app tells the user that the document doesn't allow it.
- Entering the owner password removes the restrictions for that session.
- *(Amended 2026-10-30, the user's decision.)* **That includes annotating and saving.** Annotations can be saved into encrypted documents before 1.0:
  - **Supported:** the Standard (password) security handler at revisions 2 and 3 (RC4, 40 to 128 bits), revision 4 with the `/V2` (RC4), `/AESV2` (AES-128) or `/Identity` crypt filters (strings and streams may differ, and `/EncryptMetadata false` is honoured), and revision 6 with `/AESV3` (AES-256).
  - **The file stays encrypted exactly as it was:** the same key, the same `/Encrypt` and the same `/ID`, so the same passwords open it. It is never decrypted and never re-encrypted.
  - **Still unsupported**, with an explanation and nothing changed: revision 5 (Acrobat 9's withdrawn AES-256), the public-key handler and any other non-Standard handler, custom crypt filters, and any file whose password Lectern can't authenticate itself.
  - **Unchanged:** a document whose permissions forbid annotating stays blocked until the owner password is entered (PDFKit's `allowsCommenting` is the gate), and signed, certified, Reader-extended and read-only files stay copy-only, encrypted or not.
  - **The crash journal (A1) of an encrypted document is encrypted too,** and is offered back only once the document is unlocked.

**Passwords**
- **Never stored by default.** The password prompt has a "Remember in Keychain" checkbox, unchecked by default.
- **Session restore** asks for the password again unless it was saved in the Keychain.
- **Known limitation** *(Amended 2026-10-29)*: because the app is signed ad-hoc, every update changes its signature, and macOS then asks before the new build can read a password remembered by the old one. A read that fails or is declined counts as "not saved", and the user enters the password again.

## B7. Files that change on disk

The app watches each open file and reacts to changes:

- **No unsaved annotations:** the file reloads silently and keeps the reading anchor (see A3). A brief, non-blocking "Reloaded" indicator appears.
- **Unsaved annotations:** the app asks the user to choose between:
  - **Reload:** discards the unsaved annotations.
  - **Save a Copy:** writes the unsaved annotations into a copy of the version currently open in the app.
- **File deleted:** the document stays open with a notice and offers Save a Copy.
- **File moved or renamed:** the app follows it through the file bookmark (see A2).

## B8. Search behaviour

**Matching**
- Ignores case and accents by default.
- The search field offers Match Case and Whole Word options.

**Results**
- Results appear progressively, with a match count and a progress indicator, and the UI never blocks.
- The sidebar lists results with surrounding text, and matches are highlighted on the page.
- ⌘G and ⇧⌘G move to the next and previous result.

**Scope**
- The main search covers the document's text only.
- Note text is searched with the annotation list's filter.

**Documents without text**
- A document with no text layer shows "This document has no searchable text" instead of "No results".
- A partly scanned document says how many pages have no text.

## B9. Rotation

- Rotation applies to the whole document and is view-only; it is never written to the PDF.
- It is remembered locally for each document, like zoom.

---

## Still open

- **C:** the minor items in spec-review.md: product name, how dark mode with white pages is presented as a known limitation, lazy thumbnails, and keeping "citations" in scope.
