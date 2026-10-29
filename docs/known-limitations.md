# Known limitations

Lectern 1.0 is a reader first, with highlights and notes. This page lists what it doesn't do, or doesn't do yet, and the rough edges you might meet. It's also in the app under **Help ▸ Known Limitations**.

## Installing and updating

- **macOS 26 (Tahoe) or later, on Apple Silicon only.** Intel Macs and older macOS versions aren't supported.
- **Not signed with an Apple Developer ID, and not notarised.** The app has an ad-hoc signature only. macOS blocks a downloaded copy the first time you open it, and you allow it once in **System Settings ▸ Privacy & Security ▸ Open Anyway**, or install it with Homebrew, or build it yourself. [INSTALL.md](INSTALL.md) has the steps.
- **Control-click ▸ Open doesn't get past that block.** It hasn't since macOS 15.
- **Remembered PDF passwords may need permission again after an update.** Every build has a different signature, so when a new version first reads a password an older one saved in the Keychain, macOS may ask whether to allow it. If you decline, Lectern asks for the document's password instead. Passwords are saved only if you tick "Remember in Keychain".
- **Updates are off unless you turn them on.** With them off, Lectern goes online only when you choose Check for Updates; you can also update with Homebrew or a new download.

## Reading

- **Pages are never recoloured.** Dark mode darkens the window and controls, but PDF pages keep their own colours, so a white page stays white.
- **Scanned PDFs without a text layer can't be searched, selected, highlighted or read aloud.** Lectern doesn't run text recognition (OCR) on them. It says so: search reports that the document has no searchable text, and VoiceOver hears that the page has no readable text. Notes can still be added.
- **Very long documents are searched page by page.** Results appear as they're found; on a 3,000-page manual a search for a rare word takes several seconds to finish. The results list shows the first 5,000 matches; the count includes them all.
- **Full screen isn't restored** when Lectern reopens your last session, and a tab dragged to another window is remembered only at the next open, close or quit.

## Links and active content

- **No JavaScript.** Lectern never runs a document's scripts.
- **Some link types are blocked, with an explanation:** links that launch an application or open a file (`Launch`, `file:` and similar), links to other PDF files (`GoToR`), and form submission. Web links open in your browser only when you click them, and other kinds of link (such as `mailto:`) ask first.
- **A link to a position on a page with a `/FitH` or `/FitR` destination** is previewed as the whole page, without a marker on the exact spot.

## Forms

- **Forms are read-only.** You can read filled-in forms, but not fill them in, and Lectern never changes the values in a form when it saves. A line under the toolbar says so when a document has form fields.

## Annotations

- **What you can create:** highlight, underline, strike-through, sticky notes, and comments on markup, in six colours.
- **What you can edit:** the colour and text of those, including ones made by other apps. Other apps' annotations of other kinds (shapes, ink, stamps, free text, file attachments) are shown and listed but can't be edited, recoloured or recreated after a deleted one is saved.
- **Some files can only be saved as a copy:** digitally signed files, certified files, Adobe Reader-extended forms, and files in a read-only location. ⌘S opens Save As with the reason, and the original is never changed. Many government PDFs (GovInfo, IRS forms) are signed or Reader-extended.
- **Encrypted PDFs can't be annotated.** That includes files that open without a password but carry permission restrictions, since those are encrypted too. Lectern can't save annotations into an encrypted file yet, and explains why when you try. Entering the owner password lifts the document's other restrictions, such as copying and printing, for the session, but not this one.
- **An annotation Lectern can't identify in the file** (for example, two identical annotations on top of each other from another app) can't be edited or deleted; Lectern explains instead of guessing.
- **Annotations are stored in the PDF; reader bookmarks aren't.** Bookmarks, reading positions and history stay on this Mac. Bookmarks can be exported as JSON (File ▸ Export Bookmarks…).

## Accessibility

- Controls have names and work from the keyboard, but **VoiceOver itself hasn't been tested end to end**, nor has keyboard focus inside the Settings and other SwiftUI screens.

## Performance

- **The performance targets are provisional.** They were measured on an M3 Pro, not on the base M1 with 8 GB of memory that Lectern's target hardware is, so a slower Mac may not meet them yet. [performance.md](performance.md) has the numbers.
- **Saving runs on the main thread.** On an ordinary paper it takes milliseconds, but saving one highlight into a 3,270-page, 15 MB manual took 0.73 s on an M3 Pro, and the window doesn't respond during it. Most of that is the check that the written file is intact.
- **Memory grows on very long documents.** macOS's PDF engine keeps a cache for every page it has drawn while a document is open. In a headless measurement, drawing every page of the 3,270-page manual once added about 3 GB, released only when the document closes. Closing and reopening a long document frees it. How this behaves when reading on screen with 8 GB of memory hasn't been checked yet.

## Not verified by hand yet

These work in automated tests but haven't been checked with real hardware or real apps. [release-checklist.md](release-checklist.md) lists them for the release.

- Opening a saved file in Preview and in Adobe Acrobat Reader (MuPDF, Poppler, pdf.js and PDFKit are checked automatically).
- Real trackpad hover and Force Click on links, and Tab with a physical keyboard on a form.
- Saving in place a file you chose from your own folders, under the App Sandbox.
- Reopening the last session across a real quit and relaunch.
- The first-launch update question, Sparkle's own update windows, and an update downloaded over HTTPS from GitHub.
- Homebrew's `zap` (uninstall with data removal), and **Open Anyway** itself.
