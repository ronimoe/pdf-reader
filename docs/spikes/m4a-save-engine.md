# M4a: the production save engine

**Goal:** turn the M0a incremental writer (`PDFSave`) into an API the app's save path (M4b) calls
directly: describe what's in the file, match PDFKit's annotations to file objects, apply changes,
decide whether a file can be saved in place, and prove it on real-world files.

**Result:** done. Every pass criterion of architecture §3.2 holds on all 9 real-world files and
the 14 generated ones, or the file is refused correctly by `Saveability`. Saving one highlight to a
1,000-page file takes 0.12–0.13 s in a debug build and 0.014–0.016 s in release.

- Branch `m4a-save-engine`, based on `main` at `c1e3934`.
- Measured 2026-10-29 on an Apple M3 Pro, macOS 26.6.2 (25G83), Swift 6.4, qpdf 12.4.2, MuPDF 1.28.5,
  Poppler 26.09.0, pdfjs-dist 6.4.299 on Node 26.12, pikepdf 10.17.0 and pyHanko 0.38.0.
- `PDFSave` is still Foundation and Compression only, nonisolated, and has no PDFKit outside its tests.

## API

```swift
import PDFSave

// 1. Can this file be saved, and how? (app passes whether the location is writable)
switch Saveability.evaluate(bytes, readOnlyLocation: !canWrite) {
case .inPlace:                break                 // ⌘S writes over the file
case .copyOnly(let reasons):  break                 // [.certified, .readerExtended, .signed, .readOnlyLocation]
case .unsupported(let why):   break                 // .encrypted, .malformed(String), .unsupportedStructure(String)
}

// 2. What's in the file, and which file object is each PDFAnnotation?
let doc = try PDFSaveDocument(data: bytes)
let descriptors = try doc.annotations()             // or annotations(onPage:)
let queries = pdfAnnotations.map { a in             // built by the app from PDFKit, when the file is opened
    AnnotationQuery(pageIndex: index, subtype: a.type ?? "", rect: PDFRect(a.bounds),
                    contents: a.contents, name: a.value(forAnnotationKey: .name) as? String)
}
let matches = AnnotationMatcher().match(queries, in: descriptors)
// [.matched(ObjectRef, .name | .nameAndGeometry | .geometry | .geometryAndContents),
//  .ambiguous([ObjectRef]), .notFound, .unaddressable]

// 3. Apply changes. Both calls return original + appended update.
let changes: [AnnotationChange] = [
    .addMarkup(NewMarkup(kind: .highlight, pageIndex: 0, quads: quads, color: .yellow,
                         contents: "comment", author: nil)),        // also .underline, .strikeOut
    .addNote(NewNote(pageIndex: 1, origin: PDFPoint(x: 500, y: 700), contents: "note")),
    .editContents(ref, "new text"),                                // nil removes /Contents
    .editColor(ref, PDFRGBColor(red: 0.2, green: 0.8, blue: 0.2)),
    .delete(ref),                                                  // with its /Popup and /IRT replies
]
let result = try IncrementalWriter().saveInPlace(original: bytes, changes: changes)  // refuses copy-only files
let copy   = try IncrementalWriter().saveCopy(original: bytes, changes: changes)     // for Save a Copy
// throws(PDFSaveError): .encrypted, .malformed, .unsupported, .copyOnly([CopyOnlyReason]),
//   .pageOutOfRange, .annotationNotFound, .duplicateName, .verificationFailed
// result.added: [AddedAnnotation(ref, pageIndex, subtype, name)]
```

### Describing the file

`PDFSaveDocument.annotations(onPage:)` returns one `AnnotationDescriptor` per entry of the page's
`/Annots`, in order: `ref`, `pageIndex`, `indexInAnnots`, `subtype`, `rect` (standardized),
`name` (`/NM`), `contents`, `author` (`/T`), `inReplyTo` (`/IRT`), `popup` and `color`.

- **Colour.** `/C` can have 0, 1, 3 or 4 components, so `color` is an `AnnotationColor`:
  `.transparent`, `.gray`, `.rgb` or `.cmyk`, with an `rgb` approximation.
- **Inline annotations.** An annotation dictionary written directly in `/Annots` has no object
  number, so its `ref` is nil. It is listed so that matching can say `.unaddressable` instead of
  picking a neighbour.

### Matching (`AnnotationMatcher`)

A pure function over two arrays. It never guesses: anything except `.matched` means "don't touch it".

1. **`/NM` first.** A query with a name only ever matches annotations with that name.
   - One on the same page with the same subtype is `.matched(_, .name)`.
   - A name used more than once is narrowed by geometry (`.nameAndGeometry`), otherwise `.ambiguous`.
   - A name that's only on another page or subtype is `.ambiguous`.
   - **A name that isn't in the file is `.notFound`.** It is never retried by position, so an unsaved
     annotation can't take over someone else's object.
2. **Geometry.** Otherwise the candidates must have the same page, the same subtype, and every `/Rect`
   edge within `tolerance` (default 0.05 pt).
   - **Sticky notes.** PDFKit reports every `Text` annotation as 24×24, anchored at the top-left
     corner of its `/Rect` (a 20×20 MuPDF note at y 672…692 comes back at 668…692). For notes, only
     that corner is compared.
   - **Ties.** Several candidates are narrowed by equal `/Contents`, with nil and "" treated alike
     (`.geometryAndContents`). If that doesn't leave exactly one, the result is `.ambiguous`.
3. **One-to-one.** In a batch, if two queries resolve to the same object, both become `.ambiguous`.

**Why 0.05 pt.** On every non-note annotation in the corpus (about 1,700, almost all links),
PDFKit's `bounds` equal `/Rect` to within 1e-13 pt. With an earlier 0.5 pt tolerance, four
overlapping footnote links in `arxiv-2402.16746v1`, 0.498 pt apart, came out ambiguous. At
0.05 pt they match uniquely.

**PDFKit reports `/NM`.** `value(forAnnotationKey: .name)` returns the file's `/NM`, so the app can
read our names back. When the app creates an annotation, it should set the same name on its
`PDFAnnotation`. `NewMarkup.name` and `NewNote.name` default to a fresh `lectern-<uuid>` when the
change is created.

### Changes

| Change | What is written |
|--------|-----------------|
| `addMarkup` (highlight, underline, strike-out) | `/Type /Annot /Subtype /Rect /P /F 4 /C /NM /QuadPoints /AP`, plus `/Contents` and `/T` only when given. Appearance: highlight is the quads filled with blend mode Multiply. Underline and strike-out are one stroked line per quad, at 0.1 and 0.45 of the quad's height, 1/14 of the height wide (at least 0.5 pt). |
| `addNote` | `/Subtype /Text /Name /Comment /Open false /F 28`, and a 20×20 icon `/AP` |
| `editContents` | Sets or removes `/Contents` and drops `/RC`, because Acrobat shows the rich-text `/RC` instead of `/Contents`. A FreeText annotation also loses its stale `/AP`. |
| `editColor` | Sets `/C`. When the annotation has an `/AP`: the appearance is regenerated for highlight, underline and strike-out, from `/QuadPoints`, whose corners are re-sorted because writers disagree on their order. Our own notes get a new icon. Someone else's note loses its `/AP`, so each viewer draws its own icon in the new colour. Any other subtype with an `/AP` throws `.unsupported`. Without an `/AP`, any subtype just gets the new `/C`. |
| `delete` | Removes the annotation, its `/Popup` and every `/IRT` reply (transitively) from `/Annots`. |

- **Names.** Every new annotation gets a unique `/NM`. A name already in the file or already used in
  the same save throws `.duplicateName`.
- **No hidden personal data (B4).** Nothing writes `/M`, `/CreationDate` or `/T` unless the caller
  passes it: `Options.modificationDate` (default nil) for dates, and `author` for `/T`.
  - Edits leave an existing `/M` alone.
  - A test checks that the update bytes contain no `/M`, no `/CreationDate`, no `/T`, no `D:20…`
    date and no `NSFullUserName()`, and that new annotations carry only the expected keys.
- **Journal.** `AnnotationChange` and everything in it is `Codable`, so the crash journal (§6) can
  store it as JSON. A change's `/NM` is fixed when the change is created, so a replay writes the
  same name.

### Saveability and the two save calls

- **`Saveability.evaluate(_:readOnlyLocation:)`** parses the cross-reference chain and the page
  tree, resolves every page's annotations, then reads `/Perms` and the signature fields.
  - **`copyOnly` lists every reason that applies**, in a fixed order: `certified` (`/Perms
    /DocMDP`), `readerExtended` (`/Perms /UR3` or `/UR`), `signed`, then `readOnlyLocation`. A
    certified file is also signed, so it reports `[.certified, .signed]`.
  - **Signed** means a signature field with a value. `/FT /Sig` is inherited down `/Kids`. An empty
    signature field, or `/SigFlags` on its own, doesn't count.
  - **`unsupported`** is `.encrypted`, `.malformed(reason)`, or `.unsupportedStructure(reason)`, the
    writer's deliberate refusals (data before `%PDF-`, non-Flate structural streams). It wins over
    `readOnlyLocation`.
  - It takes 0.042 s (debug) or 0.0055 s (release) on the 1,000-page file.
- **`saveInPlace`** throws `.copyOnly(reasons)` for a signed, certified or Reader-extended document.
  It can't know about the location; that's the app's part of `Saveability`.
- **`saveCopy`** is for Save a Copy: the original bytes plus the same appended update.
  - It accepts copy-only documents. The signed revision stays byte-for-byte intact, and pyHanko
    still reports the signature intact and valid with `ENTIRE_REVISION` coverage.
  - **Encrypted files are refused by both calls.** In v1 they can't be saved with annotations at all
    (architecture §4.3).

## Real-world results

Each row is one writer run, checked by `scripts/corpus/verify --markdown`. The PDFKit column and the
Saveability column come from the Swift tests.

- **Changes.** Each real-world file got a highlight on a known phrase, an underline and a strike-out
  (red) on two other wide text lines, and a note on page 1. The `@arxiv` second save, run on the
  first save's output, re-coloured our highlight, edited our note, deleted our underline and added
  an underline on page 3.
- **Copy-only files.** These went through `saveCopy`, and `saveInPlace` was checked to refuse them.

| File | Saveability | 1 Bytes prefix | 2 qpdf --check | 2b Untouched objects | 3 PDFKit annots | 4 Form fields | 5 Signature | 6 MuPDF list+draw | 6 Poppler draw | 6 pdf.js list+draw | 6 PDFKit draw | 7 Encrypted refused |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `classic-xref` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `classic-xref-no-ap` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ℹ️ drawn | ✅ | ℹ️ drawn | — |
| `xref-stream-objstm` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `incremental-existing` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `signed-approval` | copyOnly [signed] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ intact | ✅ | ✅ | ✅ | ✅ | — |
| `certified-docmdp` | copyOnly [certified, signed] | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ intact | ✅ | ✅ | ✅ | ✅ | — |
| `acroform-filled` | inPlace | ✅ | ✅ | ✅ | ✅ | ✅ (4) | — | ✅ | ✅ | ✅ | ✅ | — |
| `third-party-annots` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `mixed-page-sizes` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ (rotated page not probed) | — |
| `hybrid-xref` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `linearized-qpdf` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `@classic-xref` second save | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `@xref-stream-objstm` second save | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `arxiv-2208.04284v5` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `arxiv-2310.12457v2` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `arxiv-2402.16746v1` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `arxiv-2502.20639v1` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `arxiv-2503.00201v1` | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `nasa-tm-20180002207` (linearized) | inPlace | ✅ | ✅ ¹ | ✅ | ✅ | ✅ (0) | — | ✅ | ✅ | ✅ | ✅ | — |
| `nasa-tm-2020-220520` (linearized) | inPlace | ✅ | ✅ ¹ | ✅ | ✅ | ✅ (0) | — | ✅ | ✅ | ✅ | ✅ | — |
| `irs-fw9` (Reader-extended) | copyOnly [readerExtended] | ✅ | ✅ | ✅ | ✅ | ✅ (27) | — | ✅ | ✅ | ✅ | ✅ | — |
| `irs-f1040` (Reader-extended) | copyOnly [readerExtended] | ✅ | ✅ | ✅ | ✅ | ✅ (229) | — | ✅ | ✅ | ✅ | ✅ | — |
| `@arxiv-2208.04284v5` second save | inPlace | ✅ | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ | ✅ | — |
| `encrypted-aes256` | unsupported (encrypted) | — | — | — | — | — | — | — | — | — | — | ✅ `.encrypted` |
| `encrypted-aes256-owner-only` | unsupported (encrypted) | — | — | — | — | — | — | — | — | — | — | ✅ `.encrypted` |

✅ pass · — not applicable · ℹ️ measurement, not a criterion (the no-`/AP` variant from M0a) ·
(n) form fields compared

¹ The original already fails `qpdf --check` (exit 3, broken linearization hints). The output exits 0
with no warnings, because qpdf no longer treats it as linearized; see below.

**`verify` still catches real damage on real files.** I moved one offset in the appended
cross-reference section of three outputs by 3 bytes: the `arxiv-2208` table, and the
`nasa-tm-2020` and `irs-f1040` streams. All 12 reader checks failed:
- qpdf: "file is damaged".
- MuPDF: "repairing PDF document".
- Poppler: "xref num 131 not found", "Kid object is wrong type", or the markup not drawn.
- pdf.js: "Indexing all PDF objects", or a crash.

So comparing against the input's own warnings didn't blind the checks.

**What the real files taught us**
- **The writer itself needed no fixes for real files.** It parsed and saved all nine on the first
  run, with every byte of the original kept as a prefix. All the changes were in the checks and the
  test harness.
- **`verify` needed a baseline.** Real files make readers complain before anything is saved:
  - Both NASA files are linearized with inconsistent hint tables. `qpdf --check` exits 3 on the
    originals, with 35 and 14 warnings.
  - MuPDF prints "Repairing missing parent (P) in parent tree nodes" for both IRS forms.
  - pdf.js warns "TT: undefined function" on two TrueType fonts.

  So qpdf warnings, MuPDF and Poppler stderr, and pdf.js warnings now fail only when they are new
  compared with the unmodified input, after the file path is removed. The corruption check above
  shows that repairs are still caught.
- **Linearized files after an append.** `qpdf --check` and `--show-linearization` report the output
  as "not linearized": `/L` in the linearization dictionary no longer matches the file length. This
  is the expected, harmless outcome. Readers fall back to normal loading, and the hint-table
  warnings of the original disappear.
  - The clean `linearized-qpdf` file checks clean before the save and after it.
  - Our parser follows the final `startxref` to the first-page section at the head of the file, then
    `/Prev` to the main one. Nothing special was needed.
- **Line probes.** M0a's render probe (the mean blue over the quad drops by 40) can't see a 0.6 pt
  line. Underlines and strike-outs are now probed by counting strongly tinted pixels (red minus
  blue at least 50) in and around the quad. They must increase by at least 30% of the quad's width.
  - The first threshold (100) missed one line drawn across two pixel rows at 72 dpi.
  - The real-world lines are chosen so they don't overlap the highlight. In the first run a line
    shared a row with it and passed for the wrong reason.
- **Forms.** For the IRS forms (XFA plus AcroForm, 27 and 229 fields), every field's `/V /DV /Ff /AS`
  and every widget's `/AS` is unchanged after a Save a Copy (A5).
- **Certified.** pyHanko reports the certification signature `intact=True valid=True
  coverage=ENTIRE_REVISION`, with `modification_level=OTHER docmdp_ok=False`. The `OTHER` is
  pyHanko's known gap for annotation changes (M0a). The DocMDP P=2 file doesn't permit annotations,
  so the copy does break the certification's policy. That is why certified files are copy-only.

**Matcher on the corpus.** Every PDFKit annotation in the 23 writable cases was matched in a batch,
once for the input and once for the output (`MatchingCorpusTests`).
- **Inputs:** 1,730 annotations. 1,719 matched by geometry (almost all links, plus the IRS widgets)
  and 11 by `/NM` (the inputs of second saves).
- **Outputs:** 1,793 annotations. 1,717 matched by geometry and 76 by `/NM`.
- **No `.ambiguous`, `.notFound` or `.unaddressable` results.**
- Every match had the right page and subtype, and every annotation the writer added was matched by
  `/NM` to the object it wrote.
- **Two fixes came from this run.**
  - The sticky-note rule: the first run had 3 `.notFound` results, all MuPDF notes resized by PDFKit.
  - The tolerance cut from 0.5 pt to 0.05 pt: the first run had 4 `.ambiguous` results, the
    overlapping links in `arxiv-2402`.

## Hardening

- **Fuzzing.** The seeded fuzz now covers the real-world files: 600 mutations, against 2,000 for the
  generated files. Mutations are truncation, random bytes, and digits and delimiters at the tail and
  at the head, where linearized files keep their first-page cross-reference section.
  - Every mutant is passed to `Saveability.evaluate` and then saved with `saveCopy`, so signed and
    Reader-extended inputs exercise the writer too.
  - Every outcome is either a `PDFSaveError` or a verified save.
  - **Real-world:** 600 mutations, 269 saved and 331 refused, in 17–21 s (debug).
  - **Generated:** 2,000 mutations, 719 saved and 1,281 refused, in about 2 s.
  - No traps, and every save kept its input as a prefix.
- **Performance.** `PerformanceTests` generates two 1,000-page files, each page with its own text
  content stream under a two-level page tree: one with a classic table (360 KB), one with a
  cross-reference stream and object streams (328 KB).
  - It saves one highlight on page 638, including the writer's post-write verification. Every run
    must finish under 1 s.
  - **Measured: 0.130 s (table) and 0.122 s (streams) in debug, which is what `swift test` builds;
    0.016 s and 0.014 s in release.** Each figure is the best of three runs after a warm-up, with
    only this suite running.
  - **Under load.** Inside the full suite, which runs in parallel with the pdf.js and fuzz tests,
    the debug runs took 0.15–0.24 s.

## Known gaps

**Saving**
- **Encrypted files can't be saved with annotations in v1.** `Saveability` says `.unsupported(.encrypted)`;
  both save calls throw `.encrypted`.
- **Certified files are always copy-only, even with DocMDP P=3**, which permits annotations. A copy of
  a P=1 or P=2 file breaks its certification policy. The copy is still a valid PDF, and its signed
  revision is intact.
- **Reader-extended copies.** Adobe Reader drops the extended usage rights of a changed `/UR3` file
  and may say so when it opens the copy. Not verified, because Acrobat isn't installed.
- **Page dictionaries with duplicate keys.** Adding an annotation to such a page still throws
  `.unsupported` at save time. `Saveability` doesn't scan for this, so the app has to handle that
  error at save time as well.

**What a save writes**
- **No `/Popup`** is created for new annotations, and editing `/Contents` doesn't update a popup's
  own `/Contents`, if it has one (readers show the parent's).
- **Colour edits**
  - A colour edit on a Square, Circle, Ink, FreeText, Line or Polygon annotation that has an `/AP`
    is refused (`.unsupported`). The app should disable it for those subtypes.
  - Someone else's note loses its custom icon `/AP` on a colour edit.
  - Regenerated markup appearances assume horizontal text: corners are re-sorted by `y`, so vertical
    text gets a wrong underline.
- **Carried over from M0a:**
  - Deleted objects stay in the file, unlinked.
  - New annotations get no `/StructParent` in tagged PDFs.
  - The update is written uncompressed (a few hundred bytes per save).

**Matching**
- **Twins stay ambiguous.** Identical annotations on the same page with the same subtype, `/Rect` and
  `/Contents` can't be told apart (`indexInAnnots` is exposed but not used).
- **Match when the file is opened.** Queries must use the bounds PDFKit reported at that point, not
  after the user moved something.
- **The sticky-note rule comes from observation.** It is based on PDFKit's behaviour on macOS 26.6
  (24×24 bounds). If PDFKit changes it, `everyPDFKitAnnotationMatches` fails.

**Not verified**
- **Preview and Acrobat Reader** weren't driven (journey C step 6 is still a manual check before M4
  exits). PDFKit, MuPDF, Poppler and pdf.js all list and draw every new annotation.
- **Coverage-guided fuzzing** wasn't done. The fuzzing is seeded and deterministic.

## Reproducing

```sh
scripts/corpus/bootstrap                                   # once
cd Packages/LecternKit && LECTERN_REQUIRE_TOOLS=1 swift test
scripts/corpus/verify --manifest "$TMPDIR/lectern-corpus-pdf-reader/manifest.json" --markdown
swift test -c release -Xswiftc -enable-testing --filter PerformanceTests   # release timing
```

- **Output directory.** The corpus outputs now go to `$TMPDIR/lectern-corpus-<checkout folder>`,
  not `$TMPDIR/lectern-m0a-corpus`.
- **Why it moved.** Another worktree's `scripts/test.sh` was rewriting the shared directory while
  this one verified it, and checks failed for files that were fine. Each checkout now has its own.

## Docs to update (outside this milestone's files)

- **architecture.md §3.2.**
  - "Encrypted files are refused … and go to Save a Copy" contradicts §4.3. The writer refuses them
    in both save calls, and the app saves nothing.
  - The "Open work for production (M4)" list is done except Preview and Acrobat.
- **architecture.md §5.** `AnnotationChange` is now `Codable` and addresses existing annotations by
  `ObjectRef`. Add `AnnotationDescriptor`, `AnnotationMatcher` and `Saveability`.
- **progress.md.** Add an M4a entry.
