# Changelog

All notable changes to Lectern. Versions follow [Semantic Versioning](https://semver.org); the build number (`CFBundleVersion`) goes up by one with every release.

## 1.0.0 (build 1), unreleased

The first release: a calm, native PDF reader for macOS 26 on Apple Silicon. No accounts, no telemetry, no ads, no AI, and it works offline.

### Reading
- Native windows and tabs, recent files, and an empty state that offers only Open and your recent documents.
- Single or two-up pages, continuous or paged scrolling, cover-page and right-to-left spreads from the document's own hints, fit page, fit width and zoom that survive resizing.
- View-only rotation that is never saved into the file.
- Password-protected documents, with an opt-in "Remember in Keychain" and respect for the document's permissions.
- Printing, and distraction-free mode (⇧⌘F).

### Navigation
- A sidebar with thumbnails, the table of contents, reader bookmarks, annotations and search results.
- Go to Page using the document's own page labels.
- Back and forward history per pane that records jumps, not scrolling.
- Your place is kept across zoom, resize, layout and rotation changes, file reloads and relaunches, per document.
- Progressive search with Match Case and Whole Word, excerpts, and a clear message for scanned pages without text.

### Never losing your place
- Link previews on hover, Force Click or from the keyboard, with Go, Open in Split and Dismiss.
- A split view of the same document, each pane with its own place, zoom and history.
- Web links open only when clicked; launching apps, opening other files, form submission and scripts are blocked with an explanation.

### Annotations
- Highlight, underline, strike-through, sticky notes and comments in six named colours, with undo and redo, an annotation list, and Next/Previous Annotation.
- Saving appends to the PDF without rewriting it, checks the written file before it replaces the original, and never uses PDFKit's own save. Signed, certified and Reader-extended files are saved as a copy.
- Unsaved annotations are journaled and offered back after a crash.
- When a file changes on disk, a clean document reloads silently; one with unsaved annotations asks whether to reload or save a copy.
- Forms are shown read-only and never changed.

### Your data
- Reading positions, history, bookmarks and view settings stay on this Mac. Bookmarks export as JSON.
- Optional session restore, following the macOS setting by default.
- Optional update checks (Sparkle 2, EdDSA-signed), off unless you turn them on.

### Release
- Ad-hoc signed DMG and a Homebrew cask in the project's own tap; see [docs/INSTALL.md](docs/INSTALL.md).
- The GPL-3.0 licence and third-party notices are in the app (Help ▸ Licence, Help ▸ Acknowledgements) and on the disk image. The About panel shows the version, copyright, source repository and the no-telemetry promise.
- Help ▸ Known Limitations lists what 1.0 doesn't do; see [docs/known-limitations.md](docs/known-limitations.md).
- Performance measured on representative documents (a 475-page book, a 3,270-page manual, a 200-page image report and a scan); see [docs/performance.md](docs/performance.md).
