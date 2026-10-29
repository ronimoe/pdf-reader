# Bookmark export format

File ▸ Export Bookmarks… writes a document's reader bookmarks as JSON (decision A2: your bookmarks aren't locked in). Bookmarks live on this Mac, in the document's stored state; they are never written into the PDF.

**Version 1**, written by Lectern 0.1 and later. Implemented by `BookmarkExport` in `Packages/LecternKit/Sources/ReaderCore/ReaderBookmark.swift`.

## Example

```json
{
  "bookmarks" : [
    {
      "anchor" : {
        "x" : 0,
        "y" : 731.5
      },
      "created" : "2026-10-29T14:02:11Z",
      "name" : "Results",
      "pageIndex" : 4,
      "pageLabel" : "3"
    }
  ],
  "document" : {
    "fileName" : "paper.pdf",
    "id" : [
      "00112233445566778899aabbccddeeff",
      "8f1c0e…"
    ],
    "pageCount" : 12,
    "title" : "A Paper About Things"
  },
  "exported" : "2026-10-29T15:40:00Z",
  "format" : "io.github.ronimoe.lectern.bookmarks",
  "version" : 1
}
```

## Fields

| Field | Type | Meaning |
|---|---|---|
| `format` | string | Always `io.github.ronimoe.lectern.bookmarks`. |
| `version` | integer | The schema version, `1`. |
| `exported` | string | When the file was written, ISO 8601 in UTC. |
| `document.title` | string | The PDF's `/Title`, or the file name without its extension when the PDF has none. |
| `document.fileName` | string | The file's name when it was exported. |
| `document.id` | array of strings | The trailer's `/ID` pair, as hex. The first element is permanent; the second changes when the file is modified. Empty when the file has no `/ID`. |
| `document.pageCount` | integer | The number of pages. |
| `bookmarks` | array | In reading order: by page, then from the top of the page down. |
| `bookmarks[].name` | string | The bookmark's name. New bookmarks are called "Page <label>" until renamed. |
| `bookmarks[].pageIndex` | integer | Zero-based page index. |
| `bookmarks[].pageLabel` | string | The page's label from the PDF's `/PageLabels` (such as "iv" or "A-3"), or its one-based number. |
| `bookmarks[].anchor.x`, `.y` | number | A point in the page's own coordinate space, in PDF points: origin at the bottom left of the unrotated crop box, y growing upwards. It is the point that was at the top-left corner of the reading area when the bookmark was made. |
| `bookmarks[].created` | string | When the bookmark was made, ISO 8601 in UTC. |

## Compatibility

- Keys are written sorted and pretty-printed.
- A later version 1 may add optional fields. Readers should ignore keys they don't know.
- `version` goes up only when a field changes meaning or is removed.
- Lectern doesn't import this file yet.
