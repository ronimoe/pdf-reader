# M0a spike: saving annotations with our own incremental writer

**Question (architecture §3.2):** can our own Swift incremental-update writer save annotations safely?

**Answer: GO for candidate 1.** The prototype writer in `PDFSave` passes every applicable pass criterion
on every file in the test collection, including the whole required set: classic table,
cross-reference stream with object streams, an existing incremental update, signed (bytes intact), and
forms. No PDFium or MuPDF fallback is needed. Encrypted files are refused with a typed error and go to
Save a Copy.

- Branch `m0a-save`, based on `m0-skeleton` (`af0845d`).
- Measured 2026-10-29 on macOS 26.6.2 (Apple Silicon) with Swift 6.4, qpdf 12.4.2, MuPDF 1.28.5,
  Poppler 26.09.0, pdfjs-dist 6.4.299 on Node 26, pikepdf 10.17.0 and pyHanko 0.38.0.

## What was built

**The writer** (`Packages/LecternKit/Sources/PDFSave`, about 1,600 lines). It uses Foundation and Compression only, has no PDFKit, and is nonisolated.

| File | Role |
|------|------|
| `PDFObject.swift` | Object model. Reals keep their source text, dictionaries keep key order and strings keep raw bytes, so a rewritten object differs only where we changed it. Includes the serialiser. |
| `PDFParser.swift` | Lexer and recursive-descent parser. Handles indirect objects and streams, including an indirect `/Length`. It never repairs a file. |
| `StreamDecoder.swift` | `/FlateDecode` through `compression_stream` (raw DEFLATE, with the zlib header skipped), plus PNG predictors 10–15 and the TIFF predictor 2. |
| `PDFSaveDocument.swift` | `startxref`, then the chain of classic tables, cross-reference streams and hybrid `/XRefStm` sections, followed through `/Prev`. Resolves objects, including those in `/ObjStm`. Walks the page tree and lists annotations. Refuses `/Encrypt`. |
| `IncrementalWriter.swift` | Applies the changes, writes only the objects that must change, then appends a cross-reference section of the same kind as the latest one, a trailer and post-write verification. |
| `AppearanceStreams.swift` | Simple `/AP /N` form XObjects: the highlight is the quads filled with blend mode Multiply, and the note is a 20×20 icon. |
| `AnnotationChange.swift` | Public types: `AnnotationChange` (`addHighlight`, `addNote`, `editContents`, `delete`), `PDFSaveError` and `SaveResult`. |

**API**

```swift
let result = try IncrementalWriter().save(original: bytes, changes: [
    .addHighlight(NewHighlight(pageIndex: 0, quads: quads, color: .yellow, contents: "…", author: nil)),
    .addNote(NewNote(pageIndex: 1, origin: PDFPoint(x: 500, y: 700), contents: "…")),
    .editContents(ObjectRef(11, 0), "new text"),
    .delete(ObjectRef(13, 0)),
])   // throws(PDFSaveError): .encrypted, .malformed, .unsupported, .pageOutOfRange,
     //                       .annotationNotFound, .verificationFailed
// result.data == original + appended update
```

`PDFSaveDocument(data:)` lists the existing annotations with their object references, so edits and
deletes can address them.

**What a save writes**
- New annotation objects and their appearance streams, numbered from the old `/Size`.
- Edited annotation objects. Each keeps its number and generation, and gets new `/Contents` and `/M`.
  A FreeText annotation also loses its `/AP` and `/RC`, so viewers redraw it from the new text.
- For each touched page, its **indirect `/Annots` array** if only that page uses it. Otherwise it
  rewrites the **page object** with a direct array, so an array shared by several pages is never
  changed for all of them. Only `/Annots` changes on the page.
- Deleting an annotation also removes its `/Popup` and all its `/IRT` replies, including replies to
  replies. Editing an annotation that the same save deletes throws `.annotationNotFound`.
- **Refusals.** The writer never rewrites a dictionary that repeats a key (`.unsupported`). Readers
  keep the last value, as the parser now does, but re-serialising would drop the earlier one.
- A classic table if the latest section is a table (hybrid files count as tables), or an unfiltered
  cross-reference stream if the latest section is a stream.
- A trailer with every key of the previous trailer, plus `/Prev`, `/Size`, `/Root`, `/Info` and `/ID`.
  `/ID` keeps the first element and gets a new second element.
- **Post-write self-check.** Before returning, the writer re-parses its own output and checks:
  - the original is a prefix;
  - the new section chains to the old `startxref`;
  - the page tree resolves to the same page objects;
  - every written object reads back identically;
  - every page's `/Annots` resolves to what was written, or, on untouched pages, to exactly the
    original. Every untouched page and annotation object is also unchanged.

  If any check fails, it throws `.verificationFailed`. The self-check shares the parser with the
  writer, so it can't catch the parser's own misreadings; the external checks below cover that.

**Corpus and tooling**
- `scripts/corpus/generate` produces the files in `Tests/Corpus/public/`. Each file's source and licence
  is in `Tests/Corpus/README.md`. Everything is generated by this repo.
- `scripts/corpus/verify` checks the writer's outputs with the external tools.
- `scripts/corpus/bootstrap` sets up the `.venv` and installs `pdfjs-dist`. The `.venv` is ignored by the
  root `.gitignore`, and `node_modules` by `scripts/corpus/.gitignore`.

**Tests**
- `swift test` in `Packages/LecternKit` runs everything:
  - parser unit tests: escapes, names, references, Flate, all five PNG predictors and generation
    numbers above 0;
  - writer error paths: encrypted, a stale cross-reference and unknown targets;
  - review fixes: shared `/Annots` arrays, duplicate keys, transitive reply deletion, edit-and-delete,
    FreeText edits, hybrid precedence (table entry wins; a free table entry hides the `/XRefStm` entry,
    as in qpdf and MuPDF), indirect `/Length`, and fault injection proving `.verificationFailed` fires;
  - malformed input: oversized or negative `/Size`, `/Length`, `/XRefStm`, `/Index`, subsection and
    object-stream offsets, bad predictor parameters and a Flate bomb all throw `.malformed`;
  - a deterministic fuzz test: 2,000 seeded mutations and truncations of the corpus, each of which must
    throw a `PDFSaveError` or save and pass verification.
  - the corpus run, where criteria 1, 3 and 7 and the PDFKit render are checked in Swift.
- Seven tests each call `verify` for one external criterion.
  - Each is gated with `.enabled(if:)` on its tool, so a missing tool shows as a skipped test with a
    reason.
  - With `LECTERN_REQUIRE_TOOLS=1`, the tests run anyway and fail on a missing tool.
  - A `skip` from `verify` while the tool is present is recorded as an issue.
  - The signed and form files must report `pass`, not `n/a`.
- `swift test` passes: 57 PDFSave tests plus the existing ReaderCore and Persistence tests.

## Results

Each row is one writer run. The `@`-based cases re-save an earlier output, so the file then has two of our
sections in its chain. Columns 3 and "6 PDFKit draw" come from the Swift tests. Every other column
comes from `scripts/corpus/verify --markdown`.

| File | Changes | 1 Bytes prefix | 2 qpdf --check | 2b Untouched objects | 3 PDFKit annots | 4 Form fields | 5 Signature | 6 MuPDF list+draw | 6 Poppler draw | 6 pdf.js list+draw | 6 PDFKit draw | 7 Encrypted refused |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `classic-xref` | +2 highlights, +1 note | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `classic-xref-no-ap` | +1 highlight, +1 note, **no `/AP`** | ✅ | ✅ | ✅ | ✅ | — | — | ✅ (drawn) | ℹ️ drawn | ✅ (drawn) | ℹ️ drawn | — |
| `xref-stream-objstm` | +1 highlight (page with an indirect `/Annots`), +1 note (page inside `/ObjStm`) | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `incremental-existing` | +1 highlight, +1 note, edit the MuPDF note from the earlier update | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `signed-approval` | +1 highlight, +1 note | ✅ | ✅ | ✅ | ✅ | ✅ (1 sig field) | ✅ intact | ✅ | ✅ | ✅ | ✅ | — |
| `acroform-filled` | +1 highlight, +1 note beside 4 filled fields | ✅ | ✅ | ✅ | ✅ | ✅ (4 fields) | — | ✅ | ✅ | ✅ | ✅ | — |
| `third-party-annots` | +1 highlight, edit MuPDF Square, delete MuPDF note (and its Popup) | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `mixed-page-sizes` | highlight on all 5 pages (including `/Rotate 90` and an offset MediaBox), +1 note | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ (rotated page not probed) | — |
| `hybrid-xref` | +1 highlight, +1 note (pages exist only in the `/XRefStm`) | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `@classic-xref` second save | edit our highlight, delete our note, +1 highlight | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `@xref-stream-objstm` second save | delete our highlight, +1 highlight (stream→stream chain) | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `encrypted-aes256` | (user password) | — | — | — | — | — | — | — | — | — | — | ✅ `.encrypted` |
| `encrypted-aes256-owner-only` | (empty user password, annotation forbidden) | — | — | — | — | — | — | — | — | — | — | ✅ `.encrypted` |

✅ pass · — not applicable · ℹ️ measurement, not a criterion (see [Appearance streams](#appearance-streams))

**How each criterion is checked**
1. **Bytes prefix.** The input file must equal the first N bytes of the output. Checked in Swift and again in
   `verify`.
2. **Structure.**
   - `qpdf --check` must exit 0 with no warnings. Exit 3, which qpdf returns when it had to repair
     something, counts as a fail.
   - **2b, untouched objects** (added check). In the newest revision, every object of the original must be
     byte-identical, compared with pikepdf (resolved dictionaries, raw stream bytes), unless the writer
     declared it rewritten. A rewritten page may differ only in `/Annots`. Every new object number must be
     declared.
3. **PDFKit.** For each page, the output's list of (type, `Contents`) must equal the original's list
   after the changes are applied. PDFKit reports a `/Popup` with its parent's `Contents`, and the
   expectation models that.
4. **Form fields.** Using pikepdf, the `/AcroForm` dictionary must be unchanged. So must each field's
   `/FT /V /DV /Ff /AS` and its widgets' `/AS`, keyed by full field name and resolved.
5. **Signature.** pyHanko 0.38 validates against the throwaway certificate as the trust root. Result:
   `intact=True valid=True trusted=True coverage=ENTIRE_REVISION`, against `ENTIRE_FILE` for the
   original. Details are under [Signature](#signature-modification-level).
6. **Other readers.**
   - **Listings:** MuPDF (`mutool run`, `getAnnotations()` and widgets) and pdf.js (`getAnnotations()`)
     must list exactly the original annotations, adjusted for the changes, keyed by object number, with
     the right subtype and `Contents`.
   - **Renders** at 72 dpi from MuPDF (`mutool draw`), Poppler (`pdftoppm`), pdf.js (canvas through
     `@napi-rs/canvas`) and PDFKit: inside each new highlight's quad, the mean blue channel must drop by
     at least 40 compared with the original. It went from about 180 to 0 every time.
   - **Repair detection:** any stderr output from MuPDF or Poppler, and any pdf.js warning such as
     "Indexing all PDF objects", counts as a fail, because all of these readers repair broken files
     without saying so.
7. **Encrypted.** Both AES-256 files throw `PDFSaveError.encrypted` before anything is written.

### The checks catch broken output

To make sure the checks can fail, I corrupted outputs on purpose and ran `verify` on them:

| Corruption | Caught by |
|---|---|
| One offset in the new xref section moved by 3 bytes | qpdf ("file is damaged"), MuPDF ("repairing PDF document"), Poppler ("xref num 4 not found"), pdf.js ("Indexing all PDF objects") |
| One byte of the original changed | 1 (prefix) and 2b (object 7 changed) |
| An annotation missing from `/Annots` | MuPDF and pdf.js listings |
| A form field value changed (`name` set to "Mallory") | 4 (fields), 2b and 1 |

This exercise also found a bug in my first version of check 2b. pikepdf unparses an indirect object
as just `7 0 R`, so the comparison was empty and nothing could fail it. It now compares resolved
content.

### Signature: modification level

pyHanko reports `modification_level=OTHER, docmdp_ok=False` for the signed output. The cause is pyHanko,
not our writer:

- **The signature is fine.** It is intact, valid and trusted, and covers the whole signed revision.
- **pyHanko can't classify annotation changes.** Version 0.38 has no difference rule for them; its
  source has `TODO allow other annotation modifications, but at level ANNOTATIONS`. So any page
  `/Annots` change after signing comes out as `OTHER`.
- **MuPDF gets the same verdict.** I added a highlight to the same file with MuPDF's own
  `save("incremental")`, and pyHanko returned exactly the same result.
- **Nothing forbids the change.** The corpus signature is an approval signature without DocMDP, so
  ISO 32000 permits annotation changes.

What a certified (DocMDP) document allows is not covered here. A1 already sends every signed document to
Save a Copy, so the writer only has to avoid damaging signed files, and this shows it doesn't.

## Appearance streams

Do highlights render without an `/AP` appearance stream? I measured it with `classic-xref-no-ap`.
**Yes: PDFKit, MuPDF, Poppler and pdf.js all synthesise and draw a highlight that has no `/AP`.**

- **Sticky note without `/AP`.** pdf.js does not draw it on its canvas, because its viewer shows notes
  in the HTML annotation layer. The other readers' note rendering wasn't measured.
- **Acrobat Reader** was not available, so it isn't measured. ISO 32000-2 expects an `/AP`.

The writer therefore **generates a simple `/AP` by default** for both kinds (`Options.appearanceStreams`):
- **Highlight:** the quads filled in the chosen colour with blend mode Multiply, so the text stays readable.
- **Note:** a coloured 20×20 icon.

Every reader drew these highlights.

## Known gaps

**What the writer refuses or doesn't handle**

Every refusal is a typed error that routes the document to Save a Copy.
- **Encrypted files.**
  - The writer refuses them; criterion 7 is decided as "always Save a Copy".
  - Encrypting new objects with the document key (RC4 or AES) was not tried.
  - Permission-restricted files are always encrypted, so this also covers A1's "permissions forbid
    annotation" case.
- **Damaged files.**
  - The parser never repairs. A stale cross-reference offset, a broken `/Prev` chain or a missing
    `/Root` all throw `.malformed`.
  - How often real files hit this is unknown until the private corpus is run (A6).
- **Things that throw `.unsupported`:**
  - data before `%PDF-`;
  - `startxref` not within the last 2 KB;
  - structural streams with filters other than Flate, such as LZW or ASCIIHex;
  - Flate with a preset dictionary.
- **Never tried:**
  - **Linearized files.** Appending should only invalidate the linearization hints, and readers should
    then fall back to normal loading. Untested.
  - **Files with Reader-extended rights (`/Perms /UR3`).** Treat them like signed files.
  - **Certified (DocMDP) files.**
- **Annotations the writer can't address:**
  - Direct (inline) annotation dictionaries in `/Annots` have no object reference, so they can't be
    edited or deleted.

**What's missing from saves**
- **Deletion leaves the object in place.** A deleted annotation is unlinked, not freed, so its object
  stays in the file, which is valid. This matches what most tools do.
- **No `/Popup`** is created for new annotations.
- **Tagged PDFs.** New annotations get no `/StructParent` or structure element.
- **Editing third-party annotations** changes `/Contents` and `/M` only. FreeText loses its `/AP` and
  `/RC` so viewers regenerate it; no other subtype's appearance is regenerated.
- **Uncompressed output.** Appearance and cross-reference streams are written unfiltered. That's a few
  hundred bytes per save.

**What wasn't verified**
- **Preview** itself wasn't driven; PDFKit, its engine, was checked.
- **Acrobat Reader** isn't installed, so it is unverified.
- **The corpus is generated only.** No real-world files were tried, because `Tests/Corpus/private/` is
  empty on this machine.
- **Robustness against malformed input** is covered by a targeted test suite and a 2,000-iteration
  seeded fuzz test, not by long-running coverage-guided fuzzing.
- **Stricter than readers.** A stream `/Length` that's readable but wrong now makes the file
  `.malformed`, where readers would search for `endstream`. This only affects the streams the writer
  reads: cross-reference streams and object streams.

## What the production writer still needs (M4)

1. **Matching annotations between PDFKit and the file.**
   - PDFKit doesn't expose object numbers, so the app needs a way to match each `PDFAnnotation` to an
     `ObjectRef`.
   - For annotations we write, use `/NM`; the writer already sets a `lectern-<uuid>` name.
   - For third-party annotations, match on page index, position in `/Annots`, subtype and `/Rect`, using
     `PDFSaveDocument.annotations(onPage:)`.
   - This is the biggest open design item.
2. **More annotation types (B4):** underline and strike-through. They work like highlight with a
   different appearance stream. Also the six preset colours, an optional `/Popup`, and appearance
   streams that match PDFKit's look.
3. **Editing existing third-party annotations.**
   - Colour and quads need editing, not just `Contents`.
   - Generate a proper `/AP` for edited FreeText (today it is dropped for the viewer to regenerate).
     Keep the existing `/AP` for the others.
4. **Wiring into the save path.**
   - Snapshot the annotation changes.
   - Run `IncrementalWriter` off the main thread. Its built-in self-check runs as part of the save.
   - Reopen the result in PDFKit and compare the annotation counts.
   - Only then swap the file in through `NSDocument` safe-save.
   - On any `PDFSaveError`, or for a signed, encrypted or `/Perms` file, offer Save a Copy (A1).
5. **Scale and safety.**
   - Avoid copying the file twice: use `Data` or memory-mapped input instead of `[UInt8]`.
   - Coverage-guided fuzzing of `PDFParser` and `PDFSaveDocument` beyond the seeded test.
   - Run the writer over the private real-world corpus.
   - Decide whether to write new objects into a compressed object stream (optional).
6. **Encrypted documents.** Decide whether encrypting the new objects is worth it. The other option is
   that encrypted documents stay on Save a Copy permanently.
7. **Manual checks before M4 exits:** Preview and Acrobat Reader show the highlights and notes, which is
   journey C step 6.

## Reproducing

```sh
scripts/corpus/bootstrap                                   # once
cd Packages/LecternKit && swift test                       # writer, corpus run, all criteria
scripts/corpus/verify --manifest "$TMPDIR/lectern-m0a-corpus/manifest.json" --markdown
```

**`verify` exit codes:** 1 if any check fails, 2 if any check was skipped, 0 otherwise.

**Docs to update when this lands.** I didn't edit them here, because they're outside this spike's files:
- `architecture.md` §3.2 should be marked decided (candidate 1).
- §9 should point at `scripts/corpus/` instead of `Tests/Corpus/generate`.
- `progress.md` should get an M0a entry.
