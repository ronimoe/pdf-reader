import AppKit
import PDFKit
import ReaderCore
import ReaderKit
import ReaderUI

// MARK: Reader bookmarks (A2, spec §5.2)

extension ReaderWindowController {
    /// The focused pane's reading anchor: where ⌘D adds a bookmark.
    var bookmarkAnchor: ReadingAnchor? {
        isShowingContent ? focusedPane.view.currentAnchor : nil
    }

    /// The document's page count: stored bookmarks are clamped to it only where shown or followed.
    var bookmarkPageCount: Int { pane.view.document?.pageCount ?? .max }

    /// Whether the page being read in the focused pane has a bookmark.
    var hasBookmarkHere: Bool {
        guard let anchor = bookmarkAnchor else { return false }
        return !ReaderBookmarks.bookmarks(onPageOf: anchor, in: bookmarks, pageCount: bookmarkPageCount).isEmpty
    }

    /// Bookmarks ▸ Add Bookmark / Remove Bookmark (⌘D): adds a bookmark at the reading anchor, or
    /// removes the one bookmark on this page nearest it. The notice says which.
    @objc func toggleBookmark(_ sender: Any?) {
        guard let anchor = bookmarkAnchor else { return }
        let label = readerDocument?.label(forPageAt: anchor.pageIndex) ?? String(anchor.pageIndex + 1)
        var updated = bookmarks
        let result = ReaderBookmarks.toggle(at: anchor, name: ReaderBookmarks.defaultName(pageLabel: label), in: &updated, pageCount: bookmarkPageCount)
        bookmarks = updated
        switch result {
        case .added: notice.show("Bookmark added")
        case .removed(let removed): notice.show("Bookmark “\(removed.name)” removed")
        }
    }

    /// Jumps the focused pane to a bookmark, as a history entry (B2).
    func jumpToBookmark(_ id: UUID) {
        guard let bookmark = bookmarks.first(where: { $0.id == id }), let document = pane.view.document else { return }
        pane.jump(to: bookmark.anchor.clamped(toPageCount: document.pageCount))
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }

    /// The bookmark Rename acts on: the one selected in the list, else the one on this page.
    var bookmarkToRename: ReaderBookmark? {
        if let id = bookmarksSection.selectedItem?.id, let selected = bookmarks.first(where: { $0.id == id }) {
            return selected
        }
        guard let anchor = bookmarkAnchor else { return nil }
        return ReaderBookmarks.nearest(to: anchor, in: bookmarks, pageCount: bookmarkPageCount)
    }

    @objc func renameBookmarkMenu(_ sender: Any?) {
        guard let bookmark = bookmarkToRename else { return }
        renameBookmark(bookmark.id)
    }

    func renameBookmark(_ id: UUID) {
        guard let window, let bookmark = bookmarks.first(where: { $0.id == id }) else { return }
        presenter.renameBookmark(currentName: bookmark.name, on: window) { [weak self] name in
            guard let self, let name else { return }
            bookmarks = ReaderBookmarks.renamed(id, to: name, in: bookmarks)
        }
    }

    @objc func showBookmarkList(_ sender: Any?) { showSidebarSection(.bookmarks) }

    func refreshBookmarkList() {
        let label: (Int) -> String = { [weak readerDocument] index in readerDocument?.label(forPageAt: index) ?? String(index + 1) }
        let pageCount = bookmarkPageCount
        bookmarksSection.setItems(bookmarks.map { BookmarkListItem(id: $0.id, name: $0.name, pageLabel: label($0.anchor.clamped(toPageCount: pageCount).pageIndex)) })
    }

    // MARK: Export

    /// The JSON export (A2): the document's title and `/ID`, and each bookmark's page, label,
    /// anchor point and name. Schema in docs/bookmarks-export.md.
    func bookmarkExport(now: Date = Date()) -> BookmarkExport? {
        guard let readerDocument, let pdf = readerDocument.pdfDocument else { return nil }
        let fileName = readerDocument.fileURL?.lastPathComponent ?? readerDocument.displayName ?? "Document"
        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? (fileName as NSString).deletingPathExtension
        let ids = pdf.documentRef.map(DocumentIdentity.fileIdentifiers(of:)) ?? []
        return BookmarkExport(
            document: .init(title: title, fileName: fileName, id: ids, pageCount: pdf.pageCount),
            // The pages as they are in this version of the file.
            bookmarks: bookmarks.map { $0.clamped(toPageCount: pdf.pageCount) },
            pageLabel: { index in readerDocument.label(forPageAt: index) },
            exported: now
        )
    }

    /// File ▸ Export Bookmarks…
    @objc func exportBookmarks(_ sender: Any?) {
        guard let window, !bookmarks.isEmpty, let export = bookmarkExport() else { return }
        let name = BookmarkExport.suggestedFileName(forDocumentNamed: readerDocument?.displayName ?? "Document")
        presenter.chooseBookmarkExportDestination(suggestedName: name, on: window) { [weak self] url in
            guard let self, let url else { return }
            do {
                try export.encoded().write(to: url, options: .atomic)
            } catch {
                presenter.presentError(error, on: window) {}
            }
        }
    }
}
