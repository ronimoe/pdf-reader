import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI
import Testing
@testable import Lectern

extension M5Tests {
    @MainActor
    @Suite struct BookmarkTests {
        private func harness(store: DocumentStateStore? = nil, folder: TemporaryFolder? = nil) throws -> M5Harness {
            let data = FixturePDF.make(pageTexts: (1...6).map { "Page \($0) text" }, pageLabels: "/Nums [0 << /S /r >> 2 << /S /D >>]", id: "00112233445566778899AABBCCDDEEFF")
            if let folder, let store {
                return try M5Harness(file: try folder.write(data, to: "Bookmarked.pdf"), store: store)
            }
            return try M5Harness(data)
        }

        @Test func commandDAddsABookmarkAtTheAnchorAndRemovesItOnTheSamePage() throws {
            let h = try harness()
            defer { h.close() }
            let anchor = h.read(at: 3)
            h.controller.toggleBookmark(nil)
            #expect(h.controller.bookmarks.count == 1)
            let bookmark = try #require(h.controller.bookmarks.first)
            #expect(bookmark.anchor.isSamePlace(as: anchor))
            #expect(bookmark.name == "Page 2", "page index 3 is labelled 2 (roman i, ii, then 1, 2)")
            #expect(h.controller.hasBookmarkHere)

            // Elsewhere on the same page: ⌘D removes it rather than adding a second one.
            h.read(at: 3, y: 200)
            h.controller.toggleBookmark(nil)
            #expect(h.controller.bookmarks.isEmpty)
        }

        @Test func theMenuItemSaysAddOrRemove() throws {
            let h = try harness()
            defer { h.close() }
            h.read(at: 1)
            let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.toggleBookmark(_:)), keyEquivalent: "d")
            _ = h.controller.validateMenuItem(item)
            #expect(item.title == "Add Bookmark")
            h.controller.toggleBookmark(nil)
            _ = h.controller.validateMenuItem(item)
            #expect(item.title == "Remove Bookmark")
        }

        @Test func theSidebarListsBookmarksInReadingOrderAndAJumpIsAHistoryEntry() throws {
            let h = try harness()
            defer { h.close() }
            h.read(at: 4)
            h.controller.toggleBookmark(nil)
            h.read(at: 1)
            h.controller.toggleBookmark(nil)
            h.controller.showBookmarkList(nil)
            #expect(h.controller.sidebar.visibleSection == .bookmarks)
            let section = h.controller.bookmarksSection
            #expect(section.items.map(\.pageLabel) == ["ii", "3"])

            h.read(at: 0)
            let before = h.pane.history
            section.activate(itemAt: 1)
            #expect(h.view.currentAnchor?.pageIndex == 4)
            #expect(h.pane.history.canGoBack && !before.canGoBack, "a bookmark jump adds one history entry (B2)")
            h.controller.navigateBack(nil)
            #expect(h.view.currentAnchor?.pageIndex == 0)
        }

        @Test func renameKeepsTheBookmarkAndIgnoresABlankName() throws {
            let h = try harness()
            defer { h.close() }
            h.read(at: 2)
            h.controller.toggleBookmark(nil)
            let id = try #require(h.controller.bookmarks.first?.id)
            h.presenter.bookmarkName = "  Results  "
            h.controller.renameBookmarkMenu(nil)
            #expect(h.presenter.renamedFrom == ["Page 1"])
            #expect(h.controller.bookmarks.first?.name == "Results")
            #expect(h.controller.bookmarksSection.items.first?.name == "Results")
            h.presenter.bookmarkName = "   "
            h.controller.renameBookmark(id)
            #expect(h.controller.bookmarks.first?.name == "Results")
            h.presenter.bookmarkName = nil
            h.controller.renameBookmark(id)
            #expect(h.controller.bookmarks.first?.name == "Results")
        }

        @Test func removingFromTheListDeletesOnlyThatBookmark() throws {
            let h = try harness()
            defer { h.close() }
            h.read(at: 1)
            h.controller.toggleBookmark(nil)
            h.read(at: 5)
            h.controller.toggleBookmark(nil)
            let first = try #require(h.controller.bookmarks.first)
            h.controller.removeBookmark(first.id)
            #expect(h.controller.bookmarks.map(\.anchor.pageIndex) == [5])
        }

        @Test func bookmarksAreStoredWithTheDocumentStateAndComeBackOnReopen() throws {
            let folder = try TemporaryFolder()
            let store = folder.store()
            let h = try harness(store: store, folder: folder)
            h.read(at: 4)
            h.controller.toggleBookmark(nil)
            h.controller.saveStateNow()
            let file = try #require(h.document.fileURL)
            h.close()

            let reopened = try M5Harness(file: file, store: DocumentStateStore(directory: store.directory))
            defer { reopened.close() }
            #expect(reopened.controller.bookmarks.map(\.anchor.pageIndex) == [4])
            #expect(reopened.controller.bookmarksSection.items.map(\.name) == ["Page 3"])
        }

        @Test func bookmarksNeverReachThePDF() throws {
            let folder = try TemporaryFolder()
            let store = folder.store()
            let h = try harness(store: store, folder: folder)
            defer { h.close() }
            let file = try #require(h.document.fileURL)
            let before = try Data(contentsOf: file)
            h.read(at: 2)
            h.controller.toggleBookmark(nil)
            h.controller.saveStateNow()
            #expect(try Data(contentsOf: file) == before)
            #expect(!h.document.isDocumentEdited)
        }

        @Test func aReloadToFewerPagesClampsTheBookmarks() throws {
            let h = try harness()
            defer { h.close() }
            h.read(at: 5)
            h.controller.toggleBookmark(nil)
            let shorter = FixturePDF.make(pageTexts: ["One", "Two"])
            let pdf = try #require(PDFDocument(data: shorter))
            h.document.reload(with: shorter, pdf: pdf)
            #expect(h.controller.bookmarks.map(\.anchor.pageIndex) == [1])
        }

        @Test func exportWritesTheDocumentedSchema() throws {
            let h = try harness()
            defer { h.close() }
            h.read(at: 4, y: 500)
            h.controller.toggleBookmark(nil)
            h.read(at: 0, y: 700)
            h.controller.toggleBookmark(nil)
            h.presenter.bookmarkName = "Preface"
            h.controller.renameBookmarkMenu(nil)

            let folder = try TemporaryFolder()
            let destination = folder.url.appending(path: "export.json")
            h.presenter.bookmarkExportDestination = destination
            h.controller.exportBookmarks(nil)
            #expect(h.presenter.exportRequests.count == 1)
            #expect(h.presenter.exportRequests.first?.hasSuffix("Bookmarks.json") == true)

            let data = try Data(contentsOf: destination)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["format"] as? String == "io.github.ronimoe.lectern.bookmarks")
            #expect(json["version"] as? Int == 1)
            let document = try #require(json["document"] as? [String: Any])
            #expect((document["id"] as? [String])?.first?.lowercased() == "00112233445566778899aabbccddeeff")
            #expect(document["pageCount"] as? Int == 6)
            #expect((document["title"] as? String)?.isEmpty == false)
            let marks = try #require(json["bookmarks"] as? [[String: Any]])
            #expect(marks.map { $0["pageIndex"] as? Int } == [0, 4])
            #expect(marks.map { $0["pageLabel"] as? String } == ["i", "3"])
            #expect(marks.map { $0["name"] as? String } == ["Preface", "Page 3"])
            let anchor = try #require(marks.last?["anchor"] as? [String: Any])
            #expect(anchor["x"] is Double || anchor["x"] is Int)
            #expect(anchor["y"] is Double || anchor["y"] is Int)

            let decoded = try BookmarkExport.decode(data)
            #expect(decoded.bookmarks.count == 2)
        }

        @Test func exportIsUnavailableWithoutBookmarksAndCancelWritesNothing() throws {
            let h = try harness()
            defer { h.close() }
            let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.exportBookmarks(_:)), keyEquivalent: "")
            #expect(!h.controller.validateMenuItem(item))
            h.read(at: 1)
            h.controller.toggleBookmark(nil)
            #expect(h.controller.validateMenuItem(item))
            h.presenter.bookmarkExportDestination = nil
            h.controller.exportBookmarks(nil)
            #expect(h.presenter.exportRequests.count == 1)
        }

        @Test func theBookmarksMenuHasItsShortcuts() throws {
            let menu = MainMenu.make()
            let items = allMenuItems(menu)
            let add = try #require(items.first { $0.action == #selector(ReaderWindowController.toggleBookmark(_:)) })
            #expect(add.keyEquivalent == "d" && add.keyEquivalentModifierMask == .command)
            let show = try #require(items.first { $0.action == #selector(ReaderWindowController.showBookmarkList(_:)) })
            #expect(show.keyEquivalent == "b" && show.keyEquivalentModifierMask == [.command, .control])
            #expect(items.contains { $0.action == #selector(ReaderWindowController.exportBookmarks(_:)) })
        }
    }
}
