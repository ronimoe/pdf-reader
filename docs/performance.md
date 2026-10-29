# Performance

Spec §9.1 asks that "exact numeric performance thresholds should be established through testing on supported Mac hardware before release", on representative documents. Decision A6 names the baseline machine: **a base M1 Mac with 8 GB of memory.**

> **The thresholds below are provisional.** No base M1 with 8 GB was available for M6. Everything here was measured on an M3 Pro, and the thresholds were set from those numbers with headroom. Before 1.0 counts as meeting §9.1, run `scripts/perf.sh` on a base M1 with 8 GB and adjust the thresholds from its numbers ([release-checklist.md](release-checklist.md), §5).

## How it's measured

- **Suite:** `AppTests/M6/RepresentativePerformanceTests.swift`, run by `scripts/perf.sh`. `scripts/test.sh` skips it: the suite runs only when perf.sh has staged the files.
- **In-process and headless.** The real app code runs in the sandboxed test host: `ReaderDocument`, `ReaderWindowController`, `ReaderPDFView`, `DocumentSearch`, `PageRenderer`, `AnnotationEditor` and the `NSDocument` save path. Windows are never ordered on screen.
- **Build:** the test configuration compiled with `-O` (whole module). PDFKit and CoreGraphics are system code, optimised either way.
- **Pass or fail:** every measurement has a threshold, and a value over it fails its test. perf.sh also fails if fewer than the expected 37 measurements come back, so a suite that didn't run can't pass. Raw values go to `build/perf/results.txt`, and a table to `build/perf/summary.txt`.
- **Drawing.** PDFKit draws nothing offscreen (M0b Q11), so "drawing a page" here means `PDFPage.draw(with:to:)` into a bitmap at the pane's scale on a 2× display. That is the work PDFKit's tiles do for a page coming into view. Real display frame pacing can't be measured without a screen.

**The documents** ([Tests/Corpus/README.md](../Tests/Corpus/README.md)):

| Document | Pages | Size | Category |
|---|---:|---:|---|
| `gpo-style-manual-2016.pdf` | 475 | 4.4 MB | Long text-heavy book |
| `postgresql-17.11-US.pdf` | 3,270 | 15.4 MB | Long technical manual; 18,553 links |
| `nasa-earth-at-night.pdf` | 200 | 40.8 MB | Image-heavy report |
| `annals-surgery-1886-anthrax-scan.pdf` | 46 | 1.7 MB | Scanned, no text layer |

**The machine:** MacBook Pro, Mac15,6, Apple M3 Pro (11 cores: 5 performance, 6 efficiency), 18 GB. macOS 26.6.2 (25G83), Xcode 27.1 (27A9275). Measured 2026-10-30, on mains power, with other work running on the machine.

## Results and thresholds

The M3 Pro figures are from the last run of 2026-10-30, after the M6 review fixes (`build/perf/summary.txt` from that run). Memory figures vary between runs, because the test host's footprint carries over from earlier tests, so they're given as the range over the last four runs. The threshold is what fails the test. The aim is the reason for each threshold.

### Opening: from open to page 1 drawn

This covers reading and parsing the file, building the window, panes and sidebar, and drawing page 1. It's the median of three runs.

| Document | M3 Pro | Threshold | Aim |
|---|---:|---:|---|
| Book (475 pages) | 0.06 s | ≤ 1.0 s | Opening feels immediate |
| Manual (3,270 pages) | 0.43 s | ≤ 1.0 s | |
| Image report | 0.12 s | ≤ 1.0 s | |
| Scan | 0.09 s | ≤ 1.0 s | |

The manual's time is almost all PDFKit laying out 3,270 pages. M2 had already cut Lectern's own share for 2,000 pages to about 50 ms (architecture §4.6).

### Scrolling in continuous mode

The view is scrolled one page height per step, as a scroll wheel would, through the whole document. Each step is timed on the main thread: the scroll plus layout. The footprint is sampled after every step.

| Document | Step p95 | Threshold | Footprint growth | Threshold |
|---|---:|---:|---:|---:|
| Book | 0.1 ms | ≤ 16 ms | 60–70 MB | ≤ 1,000 MB |
| Manual | 0.8 ms (max 2.7–11 ms) | ≤ 16 ms | 467–635 MB | ≤ 1,000 MB |
| Image report | 0.1 ms | ≤ 16 ms | 30–49 MB | ≤ 1,000 MB |
| Scan | 0.1 ms | ≤ 16 ms | 25–30 MB | ≤ 1,000 MB |

The step threshold is one frame at 60 Hz.

### Drawing every page once

Each page is drawn as scrolling brings it into view, at the pane's fit-width scale (1.2–2.5) on a 2× display. The footprint is sampled once every page has been drawn.

| Document | Draw p50 | Draw p95 | Threshold (p95) | Footprint growth | Threshold |
|---|---:|---:|---:|---:|---:|
| Book | 1.0 ms | 5.8 ms | ≤ 250 ms | 265–398 MB | ≤ 800 MB |
| Manual | 1.9 ms | 3.4 ms | ≤ 250 ms | 3,060–3,170 MB | ≤ 8,000 MB |
| Image report | 29 ms | 98 ms (max 267 ms) | ≤ 250 ms | 64–94 MB | ≤ 1,200 MB |
| Scan | 43 ms | 44 ms | ≤ 250 ms | 74–90 MB | ≤ 200 MB |

PDFKit draws on background threads, so a slow page appears late; it doesn't freeze scrolling. 250 ms is about the longest a page can stay blank as it comes into view without the wait being noticeable.

**Memory is the weak spot.** PDFKit keeps a cache for every page it has drawn for as long as the document is open. A separate experiment confirmed this:
- drawing every page of the manual on a bare `PDFDocument` grew the footprint by about 1.1 GB, and none of it was released;
- scrolling without drawing grew it by about 30 MB.

Whether `PDFView`'s own on-screen drawing keeps as much, and whether macOS reclaims it under memory pressure on an 8 GB machine, can't be measured headlessly. Reading the whole 3,270-page manual in one sitting on the baseline M1 needs checking in Activity Monitor ([known-limitations.md](known-limitations.md)).

**These memory thresholds only guard against regressions on this 18 GB machine.** The manual's 8,000 MB limit in particular says nothing about whether an 8 GB Mac copes. It can't judge the baseline, and the baseline run must set real limits.

### Search

The search runs through the window controller, as when typing in the toolbar field.
- "First result" is the time until the results list first shows a match.
- "Gap" is the longest stretch the main thread went without turning its run loop, sampled every 2 ms.
- Each document gets a common word: "the" with Whole Word, 4,520 matches; and "table", 10,174 matches, past the list's 5,000-row cap. It also gets a rare word whose only match is in the last pages.

| Search | First result | Threshold | Complete | Threshold | Gap | Threshold |
|---|---:|---:|---:|---:|---:|---:|
| Book, "the" (Whole Word) | 0.15 s | ≤ 1.0 s | 3.0 s | ≤ 6 s | 55 ms | ≤ 100 ms |
| Book, "steamships" (p. 466) | — | | 2.3 s | ≤ 6 s | 51 ms | ≤ 100 ms |
| Manual, "table" | 0.46 s | ≤ 1.0 s | 9.9 s | ≤ 20 s | 40–57 ms | ≤ 100 ms |
| Manual, "retryable" (p. 3,263) | — | | 7.6 s | ≤ 20 s | 24–40 ms | ≤ 100 ms |

For a rare word, the first result *is* the completion, so only the completion is timed.

**Changed in M6: search updates are coalesced with a run-loop timer.**
- The first run of this suite showed the list empty until the search ended: 7.5 s on the manual, although the first match was found after 0.4 s.
- The cause was the test harness, not the app.
  - The coalesced update was a `DispatchQueue.main.asyncAfter` block. PDFKit posts its find notifications on the main thread.
  - A queued main-queue block can't run while the main thread is inside another one, and a `@MainActor` test that spins the run loop is exactly that.
  - Under the app's own event loop, the M6 review measured the first results after 0.21 s, with 43 updates.
- The update is now a run-loop timer, which fires in nested run loops too (modal sessions, tracking loops). It's kept for that robustness. `ReleaseTests.resultsReachTheListWhileALongSearchRuns` fails with the old coalescing.
- A common word on the manual now completes in 9.9 s here, against 7.7 s in that first run. In the first run the list and page highlights never updated during the search; now they do, as they already did in the app. So 9.9 s is the realistic figure, not a slowdown the change caused.

### Thumbnails

These come from the sidebar's renderer, which runs on its own actor with its own document. It draws 120 × 160 pt thumbnails at 2×, for the first 150 pages or the whole file.

| Document | M3 Pro | Threshold |
|---|---:|---:|
| Book | 1,358 pages/s | ≥ 20 pages/s |
| Manual | 306 pages/s | ≥ 20 pages/s |
| Image report | 168 pages/s | ≥ 20 pages/s |
| Scan | 41 pages/s | ≥ 20 pages/s |

20 pages a second fills a sidebar column faster than it can be scrolled through.

### Annotations on the 3,270-page manual

| Measurement | M3 Pro | Threshold |
|---|---:|---:|
| Building the annotation list, nothing listed | 1.5 ms | ≤ 50 ms |
| Building it with one highlight on page 2,001 | 2.7 ms | ≤ 50 ms |
| ⌘S of that highlight (main thread, `NSDocument` safe save with read-back check) | 0.73–0.75 s | ≤ 1.5 s |

**Fixed in M6: the annotation list.** M4b had flagged its cost on the main thread as unmeasured.
- It read every page's annotations: 0.53 s for the manual's 18,553 links, every time the list was rebuilt.
- It now reads only the pages that the background inspection found a listed annotation on, plus the pages changed in this session. It falls back to reading every page only until that inspection has run, or when the file's annotations can't be read (encrypted files).
- `ReleaseTests` checks that the result equals reading every page on real files, and that a highlight on a page with no annotations in the file is listed.

**Saving is a known limitation.** One highlight takes 0.73 s, and it blocks the main thread.
- A Debug build took 4.9 s, and `swift test -c release` timings of the parts match the optimised build.
- Profiled in parts:
  - the writer, with its own verification: 0.39 s (0.17 s without verification);
  - `SavedFileCheck`, which re-reads the written file and its 18,553 annotations: 0.33 s.
- Both are the safety checks of A1, so they stay. Moving the write off the main thread (`canAsynchronouslyWrite`) is the fix for later, if the baseline M1 shows it's needed.
- Ordinary files save in milliseconds: M4a measured 0.015 s on a generated 1,000-page file.

### Background work (informational, no threshold)

- **The save-readiness check of the manual,** off the main thread when it opens: about 0.95 s. That covers `Saveability`, every annotation's descriptor, and the SHA-256. Annotation actions wait for it.
- **Main-thread cost of opening a generated 2,000-page file,** beyond PDFKit's own work: about 50–59 ms. This is from M2; `OpeningPerformanceTests` runs in `scripts/test.sh`.
- **One highlight on a generated 1,000-page file, writer only:** 0.17 s in the debug `swift test` build. M4a measured 0.015 s in release. `PDFSaveTests.PerformanceTests` runs in `scripts/test.sh`, with a threshold of 1 s.

## Re-running and updating

```sh
scripts/corpus/bootstrap      # once: fetches the image report
scripts/perf.sh               # about 3 minutes
scripts/perf.sh RepresentativePerformanceTests/search   # one test, for a quick look
```

To change a threshold, edit `PerfLimit` in `AppTests/M6/RepresentativePerformanceTests.swift` and the tables above together, and say on which machine the new numbers were measured.
