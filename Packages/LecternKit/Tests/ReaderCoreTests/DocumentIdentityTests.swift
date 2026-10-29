import Foundation
import Testing
@testable import ReaderCore

private func identity(id: String? = "aa", fingerprint: String = "f1", path: String = "/a.pdf") -> DocumentIdentity {
    DocumentIdentity(
        bookmark: nil,
        fileIdentifiers: id.map { [$0, "bb"] } ?? [],
        pageCount: 10,
        fileSize: 100,
        lastKnownPath: path,
        fingerprint: fingerprint
    )
}

private func candidate(_ identity: DocumentIdentity, id: UUID = UUID(), resolvesTo path: String?, age: TimeInterval = 0) -> DocumentMatcher.Candidate {
    DocumentMatcher.Candidate(id: id, identity: identity, lastOpened: Date(timeIntervalSince1970: 1_000_000 - age), resolvedPath: path)
}

@Suite struct DocumentMatcherTests {
    @Test func anUnknownFileIsNew() {
        let match = DocumentMatcher.match(path: "/a.pdf", identity: identity(), candidates: [])
        #expect(match == .new)
        let other = candidate(identity(id: "cc", fingerprint: "f9"), resolvesTo: "/b.pdf")
        #expect(DocumentMatcher.match(path: "/a.pdf", identity: identity(), candidates: [other]) == .new)
    }

    @Test func theBookmarkWinsAndFollowsMovesAndRenames() {
        let id = UUID()
        // Stored at /old.pdf; the bookmark now resolves to the renamed file.
        let stored = candidate(identity(path: "/old.pdf"), id: id, resolvesTo: "/Renamed.pdf")
        #expect(DocumentMatcher.match(path: "/Renamed.pdf", identity: identity(path: "/Renamed.pdf"), candidates: [stored]) == .same(id, contentChanged: false))
    }

    @Test func theBookmarkWinsEvenWithoutAnID() {
        let id = UUID()
        let stored = candidate(identity(id: nil), id: id, resolvesTo: "/a.pdf")
        #expect(DocumentMatcher.match(path: "/a.pdf", identity: identity(id: nil), candidates: [stored]) == .same(id, contentChanged: false))
    }

    @Test func aFileChangedAtTheSamePathIsTheSameDocumentWithChangedContent() {
        let id = UUID()
        let stored = candidate(identity(id: "aa", fingerprint: "before"), id: id, resolvesTo: "/a.pdf")
        // A rewritten file may even get a new /ID.
        let match = DocumentMatcher.match(path: "/a.pdf", identity: identity(id: "zz", fingerprint: "after"), candidates: [stored])
        #expect(match == .same(id, contentChanged: true))
    }

    @Test func theIDIsTheFallbackWhenTheBookmarkNoLongerResolves() {
        let id = UUID()
        let stored = candidate(identity(path: "/gone.pdf"), id: id, resolvesTo: nil)
        #expect(DocumentMatcher.match(path: "/new/a.pdf", identity: identity(), candidates: [stored]) == .same(id, contentChanged: false))
    }

    @Test func aDuplicateWithTheSameIDStartsFromTheOriginal() {
        let id = UUID()
        let original = candidate(identity(), id: id, resolvesTo: "/a.pdf")
        let match = DocumentMatcher.match(path: "/a copy.pdf", identity: identity(path: "/a copy.pdf"), candidates: [original])
        #expect(match == .duplicate(of: id))
    }

    @Test func filesWithoutAnIDFallBackToIdenticalContent() {
        let id = UUID()
        let stored = candidate(identity(id: nil, fingerprint: "same"), id: id, resolvesTo: nil)
        #expect(DocumentMatcher.match(path: "/b.pdf", identity: identity(id: nil, fingerprint: "same"), candidates: [stored]) == .same(id, contentChanged: false))
        #expect(DocumentMatcher.match(path: "/b.pdf", identity: identity(id: nil, fingerprint: "other"), candidates: [stored]) == .new)
    }

    @Test func theMostRecentlyOpenedRecordWins() {
        let older = UUID(), newer = UUID()
        let candidates = [
            candidate(identity(), id: older, resolvesTo: nil, age: 100),
            candidate(identity(), id: newer, resolvesTo: nil, age: 1),
        ]
        #expect(DocumentMatcher.match(path: "/x.pdf", identity: identity(), candidates: candidates) == .same(newer, contentChanged: false))
    }
}

@Suite struct DocumentIdentityTests {
    @Test func readsTheIDPairAsHex() {
        let data = RawPDF.make(trailerExtras: "/ID [<0A0B> <0C0D>]")
        #expect(DocumentIdentity.fileIdentifiers(ofPDF: data) == ["0a0b", "0c0d"])
        #expect(DocumentIdentity.fileIdentifiers(ofPDF: RawPDF.make()).isEmpty)
    }

    @Test func theFingerprintChangesWithTheTail() {
        let data = RawPDF.make(trailerExtras: "/ID [<0A0B> <0C0D>]")
        var appended = data
        appended.append(Data("% an incremental update\n".utf8))
        #expect(DocumentIdentity.fingerprint(of: data) == DocumentIdentity.fingerprint(of: data))
        #expect(DocumentIdentity.fingerprint(of: data) != DocumentIdentity.fingerprint(of: appended))
    }

    @Test func decodesWithMissingFields() throws {
        let decoded = try JSONDecoder().decode(DocumentIdentity.self, from: Data(#"{"lastKnownPath":"/a.pdf"}"#.utf8))
        #expect(decoded.lastKnownPath == "/a.pdf")
        #expect(decoded.fileIdentifiers.isEmpty)
        #expect(decoded.bookmark == nil)
    }
}
