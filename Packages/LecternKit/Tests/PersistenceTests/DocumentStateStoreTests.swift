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
            $0.bookmarks = [ReaderBookmark(name: "Near the end", anchor: anchor(9)), ReaderBookmark(name: "Start", anchor: anchor(1))]
        }
        store.flush()

        let shorter = pdf(pages: 5, second: "02")
        try shorter.write(to: url)
        let reopened = sandbox.store().open(url: url, data: shorter, pageCount: 5)
        #expect(reopened.match == .same(first.id, contentChanged: true))
        #expect(reopened.state.anchor?.pageIndex == 4)
        #expect(reopened.state.anchor?.pointInPage == anchor(8).pointInPage)
        #expect(reopened.state.history[.primary]?.backList.map(\.pageIndex) == [4])
        // Bookmarks are stored as made; they are clamped only where shown (M5 review), so a
        // file that grows back gets them back.
        #expect(reopened.state.bookmarks.map(\.anchor.pageIndex) == [9, 1])
        #expect(reopened.state.bookmarks.map(\.name) == ["Near the end", "Start"])
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

    @Test func aCorruptIndexIsRebuiltFromTheStateFiles() throws {
        let sandbox = try Sandbox()
        let store = sandbox.store()
        var ids: [String: UUID] = [:]
        for (name, id) in [("a.pdf", "AA"), ("b.pdf", "BB")] {
            let data = pdf(pages: 8, id: id)
            let opened = store.open(url: try sandbox.write(data, to: name), data: data, pageCount: 8)
            store.update(opened.id) { $0.anchor = anchor(name == "a.pdf" ? 3 : 5) }
            ids[name] = opened.id
        }
        store.flush()
        try Data("{".utf8).write(to: store.indexURL)

        let reopened = sandbox.store()
        let a = pdf(pages: 8, id: "AA")
        let opened = reopened.open(url: sandbox.file("a.pdf"), data: a, pageCount: 8)
        #expect(opened.id == ids["a.pdf"])
        #expect(opened.state.anchor == anchor(3))
        // Every record survives, not only the one opened this session.
        reopened.flush()
        let third = sandbox.store()
        #expect(third.storedDocumentIDs == Set(ids.values))
        #expect(third.state(for: try #require(ids["b.pdf"]))?.anchor == anchor(5))
        // The unreadable index is kept aside, not deleted.
        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.storeDirectory.path)
        #expect(names.contains { $0.hasPrefix("index.unreadable-") })
    }

    @Test func aMissingIndexIsRebuiltToo() throws {
        let sandbox = try Sandbox()
        let store = sandbox.store()
        let data = pdf(pages: 4)
        let url = try sandbox.write(data, to: "a.pdf")
        let first = store.open(url: url, data: data, pageCount: 4)
        store.update(first.id) { $0.anchor = anchor(2) }
        store.flush()
        try FileManager.default.removeItem(at: store.indexURL)
        let reopened = sandbox.store().open(url: url, data: data, pageCount: 4)
        #expect(reopened.id == first.id)
        #expect(reopened.state.anchor == anchor(2))
    }

    @Test func aFailedWriteIsKeptAndRetried() throws {
        let sandbox = try Sandbox()
        let store = sandbox.store()
        let data = pdf(pages: 6)
        let first = store.open(url: try sandbox.write(data, to: "a.pdf"), data: data, pageCount: 6)
        store.update(first.id) { $0.anchor = anchor(1) }
        store.flush()

        let documents = store.documentsDirectory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: documents)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents) }
        store.update(first.id) { $0.anchor = anchor(4) }
        // A record that can't be written must not appear in the index.
        let other = pdf(pages: 2, id: "BB")
        let second = store.open(url: try sandbox.write(other, to: "b.pdf"), data: other, pageCount: 2)
        store.flush()
        #expect(sandbox.store().state(for: first.id)?.anchor == anchor(1))
        #expect(!sandbox.store().storedDocumentIDs.contains(second.id))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents)
        store.flush()
        let after = sandbox.store()
        #expect(after.state(for: first.id)?.anchor == anchor(4))
        #expect(after.storedDocumentIDs.contains(second.id))
    }

    // MARK: Pruning and forgetting (privacy)

    @Test func recordsNotOpenedForSixMonthsArePruned() throws {
        let sandbox = try Sandbox()
        let store = sandbox.store()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = pdf(pages: 1, id: "01")
        let oldID = store.open(url: try sandbox.write(old, to: "old.pdf"), data: old, pageCount: 1, now: start).id
        let recent = pdf(pages: 1, id: "02")
        let later = start.addingTimeInterval(DocumentStateStore.defaultMaximumAge + 60)
        let recentID = store.open(url: try sandbox.write(recent, to: "recent.pdf"), data: recent, pageCount: 1, now: later).id
        store.flush()
        #expect(store.storedDocumentIDs == [recentID])
        #expect(!FileManager.default.fileExists(atPath: store.stateURL(for: oldID).path))
        #expect(sandbox.store().storedDocumentIDs == [recentID])
    }

    @Test func theStoreKeepsOnlyTheNewestDocuments() throws {
        let sandbox = try Sandbox()
        let store = DocumentStateStore(directory: sandbox.storeDirectory, debounce: .seconds(60), maximumDocuments: 3)
        var ids: [UUID] = []
        for index in 0..<5 {
            let data = pdf(pages: 1, id: String(format: "%02X", index + 1))
            let url = try sandbox.write(data, to: "\(index).pdf")
            ids.append(store.open(url: url, data: data, pageCount: 1, now: Date(timeIntervalSinceNow: Double(index))).id)
        }
        store.flush()
        #expect(store.storedDocumentIDs == Set(ids.suffix(3)))
        let files = try FileManager.default.contentsOfDirectory(atPath: store.documentsDirectory.path)
        #expect(files.count == 3)
    }

    @Test func forgettingFilesRemovesTheirStateAndBookmarks() throws {
        let sandbox = try Sandbox()
        let store = sandbox.store()
        let a = pdf(pages: 2, id: "AA")
        let b = pdf(pages: 2, id: "BB")
        let aURL = try sandbox.write(a, to: "a.pdf")
        let aID = store.open(url: aURL, data: a, pageCount: 2).id
        let bID = store.open(url: try sandbox.write(b, to: "b.pdf"), data: b, pageCount: 2).id
        store.flush()

        store.forget(fileURLs: [aURL])
        store.update(aID) { $0.anchor = anchor(1) }
        store.flush()
        #expect(store.storedDocumentIDs == [bID])
        #expect(!FileManager.default.fileExists(atPath: store.stateURL(for: aID).path))
        let index = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(!index.contains("a.pdf"))
        // Opening it again starts afresh.
        #expect(sandbox.store().open(url: aURL, data: a, pageCount: 2).match == .new)
    }

    @Test func stateWithMissingFieldsStillLoads() throws {
        let identity = #"{"lastKnownPath":"/a.pdf","fileIdentifiers":["aa"]}"#
        let json = #"{"identity":\#(identity),"anchor":{"pageIndex":3,"pointInPage":[1,2],"scale":1}}"#
        let state = try DocumentStateStore.decoder.decode(DocumentState.self, from: Data(json.utf8))
        #expect(state.anchor?.pageIndex == 3)
        #expect(state.history.isEmpty)
        #expect(state.viewSettings == ViewSettings())
        // State written before the split view (M3) has none, and none before bookmarks (M5).
        #expect(state.split == nil)
        #expect(state.bookmarks.isEmpty)
    }

    @Test func bookmarksSurviveAFileShrinkingAndGrowingBack() throws {
        let sandbox = try Sandbox()
        let url = try sandbox.write(pdf(pages: 80), to: "b.pdf")
        let store = sandbox.store()
        let first = store.open(url: url, data: pdf(pages: 80), pageCount: 80)
        store.update(first.id) { $0.bookmarks = [30, 50, 70].map { ReaderBookmark(name: "p\($0)", anchor: anchor($0)) } }
        store.flush()
        let shorter = pdf(pages: 10, second: "02")
        try shorter.write(to: url)
        let small = sandbox.store()
        let shrunk = small.open(url: url, data: shorter, pageCount: 10)
        small.flush()
        #expect(shrunk.state.bookmarks.map(\.anchor.pageIndex) == [30, 50, 70])
        let longer = pdf(pages: 80, second: "03")
        try longer.write(to: url)
        let regrown = sandbox.store().open(url: url, data: longer, pageCount: 80)
        #expect(regrown.state.bookmarks.map(\.anchor.pageIndex) == [30, 50, 70])
    }

    @Test func oneDamagedBookmarkLosesOnlyItself() throws {
        let good = "{\"name\":\"good\",\"anchor\":{\"pageIndex\":2,\"pointInPage\":[1,2],\"scale\":1}}"
        let bad = "{\"name\":\"bad\",\"anchor\":42}"
        let alsoGood = "{\"name\":\"also good\",\"anchor\":{\"pageIndex\":5,\"pointInPage\":[0,0],\"scale\":1}}"
        let json = "{\"identity\":{\"lastKnownPath\":\"/a.pdf\",\"fileIdentifiers\":[\"aa\"]},\"bookmarks\":[\(good),\(bad),\(alsoGood)]}"
        let state = try DocumentStateStore.decoder.decode(DocumentState.self, from: Data(json.utf8))
        #expect(state.bookmarks.map(\.name) == ["good", "also good"])
    }

    @Test func theSplitRoundTripsWithEachPanesHistory() throws {
        let identity = DocumentIdentity(bookmark: nil, fileIdentifiers: ["aa"], pageCount: 9, fileSize: 1, lastKnownPath: "/a.pdf", fingerprint: "f")
        let second = ReadingAnchor(pageIndex: 7, pointInPage: CGPoint(x: 0, y: 400), scale: 1)
        var state = DocumentState(identity: identity)
        state.history[.primary] = HistoryStack(backList: [ReadingAnchor(pageIndex: 1, pointInPage: .zero, scale: 1)])
        state.history[.secondary] = HistoryStack(backList: [ReadingAnchor(pageIndex: 2, pointInPage: .zero, scale: 1)])
        state.split = SplitState(secondaryAnchor: second, focusedPane: .secondary)
        let data = try JSONEncoder().encode(state)
        let decoded = try DocumentStateStore.decoder.decode(DocumentState.self, from: data)
        #expect(decoded.split == state.split)
        #expect(decoded.history == state.history)
        // A file that shrank clamps the second pane's place too.
        #expect(decoded.clamped(toPageCount: 3).split?.secondaryAnchor?.pageIndex == 2)
        // A damaged split entry is dropped, not the whole state.
        let damaged = #"{"identity":{"lastKnownPath":"/a.pdf","fileIdentifiers":["aa"]},"split":{"focusedPane":42}}"#
        let partial = try DocumentStateStore.decoder.decode(DocumentState.self, from: Data(damaged.utf8))
        #expect(partial.split?.focusedPane == .primary)
    }

    @Test func pathsThroughSymlinksCompareEqual() throws {
        let sandbox = try Sandbox()
        let url = try sandbox.write(pdf(pages: 1), to: "a.pdf")
        // The temporary folder lives under /var, a symlink to /private/var.
        let other = url.path.hasPrefix("/private/") ? String(url.path.dropFirst("/private".count)) : "/private" + url.path
        #expect(DocumentStateStore.path(of: url) == DocumentStateStore.path(of: URL(fileURLWithPath: other)))
    }

    @Test func theDefaultDirectoryIsApplicationSupportForTheBundle() {
        let directory = DocumentStateStore.defaultDirectory(bundleIdentifier: "io.example.Test")
        #expect(directory.path.hasSuffix("Application Support/io.example.Test"))
    }
}
