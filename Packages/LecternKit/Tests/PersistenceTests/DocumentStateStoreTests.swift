import CoreGraphics
import Foundation
import ReaderCore
import Synchronization
import Testing
@testable import Persistence

/// A temporary directory holding a store root and the "user's" PDFs. Nothing
/// here touches the app's real container.
private struct Sandbox: ~Copyable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "LecternStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Files"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var storeDirectory: URL { root.appending(path: "Store", directoryHint: .isDirectory) }

    func store(bookmarks: any FileBookmarking = SecurityScopedBookmarks(), debounce: Duration = .seconds(60)) -> DocumentStateStore {
        DocumentStateStore(directory: storeDirectory, bookmarks: bookmarks, debounce: debounce)
    }

    func file(_ name: String) -> URL { root.appending(path: "Files/\(name)") }

    @discardableResult
    func write(_ data: Data, to name: String) throws -> URL {
        let url = file(name)
        try data.write(to: url)
        return url
    }
}

private func pdf(pages: Int, id: String? = "0A0B0C", second: String = "01") -> Data {
    RawPDF.make(trailerExtras: id.map { "/ID [<\($0)> <\(second)>]" } ?? "", pageRotations: Array(repeating: 0, count: pages))
}

private func anchor(_ page: Int) -> ReadingAnchor {
    ReadingAnchor(pageIndex: page, pointInPage: CGPoint(x: 10, y: 500), scale: 1.25)
}

/// Bookmarks that never resolve, to exercise the /ID fallback.
private struct BrokenBookmarks: FileBookmarking {
    func bookmarkData(for url: URL) -> Data? { Data("broken".utf8) }
    func resolve(_ data: Data) -> URL? { nil }
}

@Suite struct DocumentStateStoreTests {
    @Test func aNewDocumentStartsWithDefaults() throws {
        let sandbox = try Sandbox()
        let data = pdf(pages: 3)
        let url = try sandbox.write(data, to: "a.pdf")
        let opened = sandbox.store().open(url: url, data: data, pageCount: 3)
        #expect(opened.match == .new)
        #expect(opened.state.anchor == nil)
        #expect(opened.state.history.isEmpty)
        #expect(opened.state.viewSettings == ViewSettings())
        #expect(opened.state.identity.fileIdentifiers == ["0a0b0c", "01"])
        #expect(opened.state.identity.pageCount == 3)
        #expect(opened.state.identity.bookmark != nil)
    }

    @Test func everythingStoredComesBackOnReopen() throws {
        let sandbox = try Sandbox()
        let data = pdf(pages: 10)
        let url = try sandbox.write(data, to: "a.pdf")
        let store = sandbox.store()
        let first = store.open(url: url, data: data, pageCount: 10)
        var history = HistoryStack()
        history.recordJump(from: anchor(2))
        var settings = ViewSettings(pages: .twoUp, scrolling: .paged, coverPageAlone: true, rightToLeft: true, rotation: 90, zoom: .scale(1.5))
        settings.sidebar = SidebarSettings(isVisible: true, section: .outline)
        store.update(first.id) {
            $0.anchor = anchor(7)
            $0.history = [.primary: history]
            $0.viewSettings = settings
        }
        store.flush()

        // A fresh store, as after relaunching the app.
        let reopened = sandbox.store().open(url: url, data: data, pageCount: 10)
        #expect(reopened.id == first.id)
        #expect(reopened.match == .same(first.id, contentChanged: false))
        #expect(reopened.state.anchor == anchor(7))
        #expect(reopened.state.history[.primary]?.backList == [anchor(2)])
        #expect(reopened.state.viewSettings == settings)
    }

    @Test func writesAreDebouncedUntilFlushed() throws {
        let sandbox = try Sandbox()
        let data = pdf(pages: 2)
        let url = try sandbox.write(data, to: "a.pdf")
        let store = sandbox.store(debounce: .seconds(60))
        let opened = store.open(url: url, data: data, pageCount: 2)
        store.update(opened.id) { $0.anchor = anchor(1) }
        #expect(!FileManager.default.fileExists(atPath: store.stateURL(for: opened.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.indexURL.path))
        store.flush()
        #expect(FileManager.default.fileExists(atPath: store.stateURL(for: opened.id).path))
        #expect(FileManager.default.fileExists(atPath: store.indexURL.path))
    }

    @Test func debouncedWritesLandOnTheirOwn() async throws {
        let sandbox = try Sandbox()
        let data = pdf(pages: 2)
        let url = try sandbox.write(data, to: "a.pdf")
        let store = sandbox.store(debounce: .milliseconds(50))
        let opened = store.open(url: url, data: data, pageCount: 2)
        store.update(opened.id) { $0.anchor = anchor(1) }
        let path = store.stateURL(for: opened.id).path
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let written = try DocumentStateStore.decoder.decode(DocumentState.self, from: Data(contentsOf: store.stateURL(for: opened.id)))
        #expect(written.anchor == anchor(1))
    }

    @Test func storageIsOneFilePerDocumentPlusAnIndex() throws {
        let sandbox = try Sandbox()
        let store = sandbox.store()
        for name in ["a.pdf", "b.pdf"] {
            let data = pdf(pages: 2, id: name == "a.pdf" ? "AA" : "BB")
            store.open(url: try sandbox.write(data, to: name), data: data, pageCount: 2)
        }
        store.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: store.documentsDirectory.path)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.hasSuffix(".json") })
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL)) as? [String: Any]
        #expect((index?["documents"] as? [String: Any])?.count == 2)
    }

    // MARK: Identity (A2)

    @Test func aRenamedOrMovedFileIsFollowedThroughItsBookmark() throws {
        let sandbox = try Sandbox()
        // No /ID, so only the bookmark can recognise it after the move.
        let data = pdf(pages: 4, id: nil)
        let url = try sandbox.write(data, to: "draft.pdf")
        let store = sandbox.store()
        let first = store.open(url: url, data: data, pageCount: 4)
        store.update(first.id) { $0.anchor = anchor(3) }
        store.flush()

        try FileManager.default.createDirectory(at: sandbox.file("Moved"), withIntermediateDirectories: true)
        let moved = sandbox.file("Moved/final.pdf")
        try FileManager.default.moveItem(at: url, to: moved)
        // Edit the content too, so the fingerprint can't be what matched.
        var changed = data
        changed.append(Data("% edited\n".utf8))
        try changed.write(to: moved)

        let reopened = sandbox.store().open(url: moved, data: changed, pageCount: 4)
        #expect(reopened.id == first.id)
        #expect(reopened.state.anchor == anchor(3))
        #expect(reopened.state.identity.lastKnownPath.hasSuffix("Moved/final.pdf"))
    }

    @Test func aFileChangedAtTheSamePathIsRemappedAndClamped() throws {
        let sandbox = try Sandbox()
        let data = pdf(pages: 10)
        let url = try sandbox.write(data, to: "a.pdf")
        let store = sandbox.store()
        let first = store.open(url: url, data: data, pageCount: 10)
        var history = HistoryStack()
        history.recordJump(from: anchor(9))
        store.update(first.id) {
            $0.anchor = anchor(8)
            $0.history = [.primary: history]
        }
        store.flush()

        let shorter = pdf(pages: 5, second: "02")
        try shorter.write(to: url)
        let reopened = sandbox.store().open(url: url, data: shorter, pageCount: 5)
        #expect(reopened.match == .same(first.id, contentChanged: true))
        #expect(reopened.state.anchor?.pageIndex == 4)
        #expect(reopened.state.anchor?.pointInPage == anchor(8).pointInPage)
        #expect(reopened.state.history[.primary]?.backList.map(\.pageIndex) == [4])
        #expect(reopened.state.identity.pageCount == 5)
    }

    @Test func aDuplicateStartsFromTheOriginalAndThenDiverges() throws {
        let sandbox = try Sandbox()
        let data = pdf(pages: 6)
        let original = try sandbox.write(data, to: "paper.pdf")
        let store = sandbox.store()
        let first = store.open(url: original, data: data, pageCount: 6)
        store.update(first.id) { $0.anchor = anchor(4) }

        let copy = sandbox.file("paper copy.pdf")
        try FileManager.default.copyItem(at: original, to: copy)
        let duplicate = store.open(url: copy, data: data, pageCount: 6)
        #expect(duplicate.match == .duplicate(of: first.id))
        #expect(duplicate.id != first.id)
        #expect(duplicate.state.anchor == anchor(4))

        store.update(duplicate.id) { $0.anchor = anchor(1) }
        #expect(store.state(for: first.id)?.anchor == anchor(4))
        // Each now opens as itself.
        store.flush()
        let again = sandbox.store()
        #expect(again.open(url: copy, data: data, pageCount: 6).id == duplicate.id)
        #expect(again.open(url: original, data: data, pageCount: 6).id == first.id)
    }

    @Test func theIDIsTheFallbackWhenBookmarksDontResolve() throws {
        let sandbox = try Sandbox()
        let data = pdf(pages: 3)
        let url = try sandbox.write(data, to: "a.pdf")
        let store = sandbox.store(bookmarks: BrokenBookmarks())
        let first = store.open(url: url, data: data, pageCount: 3)
        store.update(first.id) { $0.anchor = anchor(2) }
        let elsewhere = try sandbox.write(data, to: "b.pdf")
        try FileManager.default.removeItem(at: url)
        let reopened = store.open(url: elsewhere, data: data, pageCount: 3)
        #expect(reopened.id == first.id)
        #expect(reopened.state.anchor == anchor(2))
    }

    @Test func anUnreadableIndexStartsAfresh() throws {
        let sandbox = try Sandbox()
        try FileManager.default.createDirectory(at: sandbox.storeDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: sandbox.storeDirectory.appending(path: "index.json"))
        let data = pdf(pages: 1)
        let opened = sandbox.store().open(url: try sandbox.write(data, to: "a.pdf"), data: data, pageCount: 1)
        #expect(opened.match == .new)
    }

    @Test func stateWithMissingFieldsStillLoads() throws {
        let identity = #"{"lastKnownPath":"/a.pdf","fileIdentifiers":["aa"]}"#
        let json = #"{"identity":\#(identity),"anchor":{"pageIndex":3,"pointInPage":[1,2],"scale":1}}"#
        let state = try DocumentStateStore.decoder.decode(DocumentState.self, from: Data(json.utf8))
        #expect(state.anchor?.pageIndex == 3)
        #expect(state.history.isEmpty)
        #expect(state.viewSettings == ViewSettings())
    }

    @Test func theDefaultDirectoryIsApplicationSupportForTheBundle() {
        let directory = DocumentStateStore.defaultDirectory(bundleIdentifier: "io.example.Test")
        #expect(directory.path.hasSuffix("Application Support/io.example.Test"))
    }
}
