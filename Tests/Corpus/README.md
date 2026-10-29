# Test PDF collection

Redistributable test PDFs (decision A6). Every file in `public/` is **generated from scratch** by
`scripts/corpus/generate`. No third-party documents, fonts or images are embedded (only the 14
standard fonts, by name). Generated files are covered by this repository's licence (GPL-3.0).

Private, non-redistributable PDFs go in `private/`, which is git-ignored.

## Regenerating

```sh
scripts/corpus/bootstrap   # once: .venv (pikepdf, pyHanko, reportlab) + pdfjs-dist
scripts/corpus/generate    # rewrites public/*.pdf
```

Needs qpdf and mupdf-tools from Homebrew. Output isn't byte-reproducible (the signature, the
AES salt and MuPDF's IDs change each run), so regenerate only when the cases change, and re-run
`swift test` in `Packages/LecternKit` afterwards.

## Files

| File | Structure it exercises | Made with | Source and licence |
|------|------------------------|-----------|--------------------|
| `classic-xref.pdf` | Classic `xref` table, single revision, 2 pages, no `/Annots` | reportlab 5.1 (`invariant=1`) | Generated; GPL-3.0 (this repo) |
| `xref-stream-objstm.pdf` | Cross-reference stream (`/W`, PNG predictor 12) and an object stream holding the pages; page 1 has an **indirect** `/Annots` array with a Link | reportlab → pikepdf 10.17 (`object_stream_mode=generate`) | Generated; GPL-3.0 |
| `incremental-existing.pdf` | Two revisions: original plus an incremental update that added a Text note with a Popup (`/Prev` chain) | reportlab → MuPDF 1.28 `save("incremental")` (`mupdf-annotate.js`) | Generated; GPL-3.0 |
| `signed-approval.pdf` | Approval signature (no DocMDP) in an incremental update; visible signature widget on page 1 | reportlab → pyHanko 0.38, throwaway self-signed RSA-2048 certificate made by the script | Generated; GPL-3.0 |
| `signed-approval.cert.pem` | The public certificate for the file above, used as the trust root by `verify` (the private key is discarded) | `cryptography` | Generated; GPL-3.0 |
| `acroform-filled.pdf` | AcroForm with two filled text fields (one non-ASCII) and two checkboxes (one checked); fields, widgets and page inside object streams | reportlab acroForm → `qpdf --object-streams=generate` | Generated; GPL-3.0 |
| `third-party-annots.pdf` | Square, Text (with Popup) and Highlight annotations written by another tool, with `/AP` | reportlab → MuPDF 1.28 (`mupdf-annotate.js`) | Generated; GPL-3.0 |
| `mixed-page-sizes.pdf` | Letter, A4 landscape, A5, Legal with `/Rotate 90`, and a MediaBox with a non-zero origin; **nested** `/Pages` tree with inherited `/Resources` | Hand-written by `generate.py` (MiniPDF) | Generated; GPL-3.0 |
| `hybrid-xref.pdf` | Hybrid file: classic table plus `/XRefStm`; pages, page tree and font live only in an object stream | Hand-written by `generate.py` (MiniPDF) | Generated; GPL-3.0 |
| `encrypted-aes256.pdf` | AES-256 (R6), user password `user-pass`, owner password `owner-pass` | `qpdf --encrypt … 256` | Generated; GPL-3.0 |
| `encrypted-aes256-owner-only.pdf` | AES-256 with an empty user password (opens without a prompt) and annotation/modification forbidden | `qpdf --encrypt "" … 256 --modify=none --annotate=n` | Generated; GPL-3.0 |

The page text is original filler written for this corpus.

## How it's used

`swift test` in `Packages/LecternKit` runs the incremental writer (`PDFSave`) over each file
(`Tests/PDFSaveTests/CorpusSupport.swift` lists the changes per file), writes the outputs and a
`manifest.json` to `$TMPDIR/lectern-m0a-corpus/` (override with `LECTERN_CORPUS_OUT`), and calls
`scripts/corpus/verify` for the external checks. Run it by hand for a readable report:

```sh
scripts/corpus/verify --manifest "$TMPDIR/lectern-m0a-corpus/manifest.json"            # text
scripts/corpus/verify --manifest "$TMPDIR/lectern-m0a-corpus/manifest.json" --markdown # table
```
