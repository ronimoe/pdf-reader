# Test PDF collection

Redistributable test PDFs (decision A6), in two groups:

- **`public/*.pdf` is generated from scratch** by `scripts/corpus/generate`. No third-party documents,
  fonts or images are embedded (only the 14 standard fonts, by name). Generated files are covered by
  this repository's licence (GPL-3.0).
- **`public/realworld/` holds downloaded real-world files** whose licences allow redistribution
  (CC BY 4.0, CC0 1.0, or US Government works in the public domain). They are committed unchanged;
  each one's source, licence and SHA-256 are listed [below](#real-world-files). They are never
  regenerated.

Private, non-redistributable PDFs go in `private/`, which is git-ignored.

## Regenerating

```sh
scripts/corpus/bootstrap                     # once: .venv (pikepdf, pyHanko, reportlab) + pdfjs-dist
scripts/corpus/generate                      # rewrites every generated file in public/
scripts/corpus/generate --only linearized-qpdf certified-docmdp   # rewrites just these
```

Needs qpdf and mupdf-tools from Homebrew. Output isn't byte-reproducible (the signatures, the
AES salt and MuPDF's IDs change each run), so regenerate only the files whose cases change (`--only`),
and re-run `swift test` in `Packages/LecternKit` afterwards. The names `--only` accepts are the file
names without `.pdf`, plus `encrypted` for both encrypted files.

## Generated files

| File | Structure it exercises | Made with | Source and licence |
|------|------------------------|-----------|--------------------|
| `classic-xref.pdf` | Classic `xref` table, single revision, 2 pages, no `/Annots` | reportlab 5.1 (`invariant=1`) | Generated; GPL-3.0 (this repo) |
| `xref-stream-objstm.pdf` | Cross-reference stream (`/W`, PNG predictor 12) and an object stream holding the pages; page 1 has an **indirect** `/Annots` array with a Link | reportlab → pikepdf 10.17 (`object_stream_mode=generate`) | Generated; GPL-3.0 |
| `incremental-existing.pdf` | Two revisions: original plus an incremental update that added a Text note with a Popup (`/Prev` chain) | reportlab → MuPDF 1.28 `save("incremental")` (`mupdf-annotate.js`) | Generated; GPL-3.0 |
| `signed-approval.pdf` | Approval signature (no DocMDP) in an incremental update; visible signature widget on page 1 | reportlab → pyHanko 0.38, throwaway self-signed RSA-2048 certificate made by the script | Generated; GPL-3.0 |
| `signed-approval.cert.pem` | The public certificate for the file above, used as the trust root by `verify` (the private key is discarded) | `cryptography` | Generated; GPL-3.0 |
| `certified-docmdp.pdf` | **Certification** signature: `/Perms /DocMDP` with P=2 (form filling only, so annotations are not permitted), in an incremental update | reportlab → pyHanko 0.38 (`certify=True`, `MDPPerm.FILL_FORMS`), throwaway certificate | Generated; GPL-3.0 |
| `certified-docmdp.cert.pem` | Its public certificate (trust root for `verify`) | `cryptography` | Generated; GPL-3.0 |
| `acroform-filled.pdf` | AcroForm with two filled text fields (one non-ASCII) and two checkboxes (one checked); fields, widgets and page inside object streams | reportlab acroForm → `qpdf --object-streams=generate` | Generated; GPL-3.0 |
| `third-party-annots.pdf` | Square, Text (with Popup) and Highlight annotations written by another tool, with `/AP` | reportlab → MuPDF 1.28 (`mupdf-annotate.js`) | Generated; GPL-3.0 |
| `mixed-page-sizes.pdf` | Letter, A4 landscape, A5, Legal with `/Rotate 90`, and a MediaBox with a non-zero origin; **nested** `/Pages` tree with inherited `/Resources` | Hand-written by `generate.py` (MiniPDF) | Generated; GPL-3.0 |
| `hybrid-xref.pdf` | Hybrid file: classic table plus `/XRefStm`; pages, page tree and font live only in an object stream | Hand-written by `generate.py` (MiniPDF) | Generated; GPL-3.0 |
| `linearized-qpdf.pdf` | **Linearized** (first-page cross-reference section at the start, `startxref` pointing at it, valid hint tables: `qpdf --check-linearization` is clean) | reportlab → `qpdf --linearize` | Generated; GPL-3.0 |
| `encrypted-aes256.pdf` | AES-256 (R6), user password `user-pass`, owner password `owner-pass` | `qpdf --encrypt … 256` | Generated; GPL-3.0 |
| `encrypted-aes256-owner-only.pdf` | AES-256 with an empty user password (opens without a prompt) and annotation/modification forbidden | `qpdf --encrypt "" … 256 --modify=none --annotate=n` | Generated; GPL-3.0 |

The page text is original filler written for this corpus.

## Real-world files

Downloaded 2026-10-29 into `public/realworld/`, unmodified. The arXiv licence was read from each
paper's abstract page (`https://arxiv.org/abs/<id>`) for the version listed; NASA's from the NTRS
record (`GOV_PUBLIC_USE_PERMITTED`: authored by US Government employees). US Government works are
not subject to copyright in the United States (17 U.S.C. §105).

| File | Source URL | Licence | SHA-256 | Bytes |
|------|------------|---------|---------|------:|
| `arxiv-2208.04284v5.pdf` | https://arxiv.org/pdf/2208.04284v5 | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) | `60e24b186b08a1e0c29e3a898ca5f67132058ccefa8c88f02999d7a1cb1bcb26` | 862,281 |
| `arxiv-2310.12457v2.pdf` | https://arxiv.org/pdf/2310.12457v2 | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) | `7f60459eb5b3f2f65aeeedcbe91af42c308eef705acc09a0d4796ad6c5645359` | 617,238 |
| `arxiv-2402.16746v1.pdf` | https://arxiv.org/pdf/2402.16746v1 | [CC BY 4.0](http://creativecommons.org/licenses/by/4.0/) | `2ca16fe2aa4f1b8d70dd2fb7ff61e8eaa747a0ce5da92332c455ef418caea0f0` | 1,255,119 |
| `arxiv-2502.20639v1.pdf` | https://arxiv.org/pdf/2502.20639v1 | [CC0 1.0](http://creativecommons.org/publicdomain/zero/1.0/) | `77024d96807ec31915e5d4929098301810a70f3eca12b3511532129436016efc` | 2,243,669 |
| `arxiv-2503.00201v1.pdf` | https://arxiv.org/pdf/2503.00201v1 | [CC0 1.0](http://creativecommons.org/publicdomain/zero/1.0/) | `c748c0b447a575497d84019f5ab0909dcae45594e2c3e9ad9ffdeccf8f954563` | 1,151,959 |
| `nasa-tm-20180002207.pdf` | https://ntrs.nasa.gov/api/citations/20180002207/downloads/20180002207.pdf | US Government work, public domain | `e2281d1219f6c08cbe9114b6b5dc60a6e4d138e439f92f55caf1844e6f7b33af` | 1,130,862 |
| `nasa-tm-2020-220520.pdf` | https://ntrs.nasa.gov/api/citations/20200004351/downloads/TM-2020-220520.pdf | US Government work, public domain | `6ffe62706441ff005e1a4a73bd438296f945108e628dcf28b63bce66b6754b73` | 1,529,632 |
| `irs-fw9.pdf` | https://www.irs.gov/pub/irs-pdf/fw9.pdf | US Government work, public domain | `2d420cbb4123dcf1fb82595b2359cfbb5d81f00b9df9d359fcc7af361d093f53` | 140,815 |
| `irs-f1040.pdf` | https://www.irs.gov/pub/irs-pdf/f1040.pdf | US Government work, public domain | `3d31c226df0d189ced80e039d01cf0f8820c1019681a0f0ca6264de277b7e982` | 220,237 |

Total 9.15 MB. The IRS URLs always serve the current revision of the form, so a fresh download will
differ; the SHA-256 identifies the copy committed here (W-9 Rev. March 2024; Form 1040 for 2025).

**Attribution (CC BY 4.0).** The files are redistributed unchanged.
- `arxiv-2208.04284v5.pdf`: Lan V. Truong, "On Rademacher Complexity-based Generalization Bounds for Deep Learning", arXiv:2208.04284v5.
- `arxiv-2310.12457v2.pdf`: Haitian Jiang, Renjie Liu, Zengfeng Huang, Yichuan Wang, Xiao Yan, Zhenkun Cai, Minjie Wang, David Wipf, "MuseGNN: Forming Scalable, Convergent GNN Layers that Minimize a Sampling-Based Energy", arXiv:2310.12457v2.
- `arxiv-2402.16746v1.pdf`: Chinmay Patwardhan, Martin Frank, Jonas Kusch, "Asymptotic-preserving and energy stable dynamical low-rank approximation for thermal radiative transfer equations", arXiv:2402.16746v1.

**CC0 and public domain, credited for reference.**
- `arxiv-2502.20639v1.pdf`: Leming Shen et al., "FedConv: A Learning-on-Model Paradigm for Heterogeneous Federated Clients", arXiv:2502.20639v1.
- `arxiv-2503.00201v1.pdf`: Keroshan Pillay, "Path Dependence in AMM-Based Markets: Mathematical Proof and Implications for Truth Discovery", arXiv:2503.00201v1.
- `nasa-tm-20180002207.pdf`: NASA/TM—2018–219882, "A Rain Taxonomy for Degraded Visual Environment Mitigation" (NTRS 20180002207).
- `nasa-tm-2020-220520.pdf`: NASA/TM—2020-220520, "Integrated Radio and Optical Communications (iROC) Primary, Secondary, and Tertiary Optics Alignment Procedure" (NTRS 20200004351).
- `irs-fw9.pdf`, `irs-f1040.pdf`: Internal Revenue Service, Form W-9 and Form 1040.

**What each one exercises**

| File | Structure | Why it's here |
|------|-----------|---------------|
| `arxiv-*` (5 files) | pdfTeX 1.40, classic `xref` table, single revision; 14–52 pages; outlines of 22–32 entries; 17–420 internal links (`/Dest` cross-references and citations) | Real papers with internal links and an outline, for the writer now and for M3's link layer later |
| `nasa-tm-20180002207.pdf` | Adobe PDF Library 15; **linearized**; cross-reference streams and object streams; two revisions | A real linearized file whose hint tables are already inconsistent (`qpdf --check` exits 3 with 35 warnings before we touch it) |
| `nasa-tm-2020-220520.pdf` | Acrobat Distiller 17; **linearized**; cross-reference streams; outline and 28 internal links | Second real linearized file, also with pre-existing hint-table warnings (14) |
| `irs-fw9.pdf`, `irs-f1040.pdf` | Adobe LiveCycle Designer; XFA plus AcroForm (27 and 229 fields); **Reader-extended (`/Perms /UR3`)**; cross-reference streams; three revisions | Real Reader-extended forms: `Saveability` must route them to Save a Copy, and the copy must leave every field unchanged (A5) |

## How it's used

`swift test` in `Packages/LecternKit` runs the incremental writer (`PDFSave`) over each file
(`Tests/PDFSaveTests/CorpusSupport.swift` lists the changes and the expected `Saveability` per
file), and writes the outputs and a `manifest.json` to `$TMPDIR/lectern-corpus-<checkout folder>/`.
For the main checkout that is `lectern-corpus-pdf-reader`; each git worktree gets its own, so
parallel runs don't overwrite each other. `LECTERN_CORPUS_OUT` overrides it. It then calls
`scripts/corpus/verify` for the external checks. Run that by hand for a readable report:

```sh
scripts/corpus/verify --manifest "$TMPDIR/lectern-corpus-pdf-reader/manifest.json"            # text
scripts/corpus/verify --manifest "$TMPDIR/lectern-corpus-pdf-reader/manifest.json" --markdown # table
```

The seeded fuzz tests (`RobustnessTests`) mutate every file here, including `realworld/`.
