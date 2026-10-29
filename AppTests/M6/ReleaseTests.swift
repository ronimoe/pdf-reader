import AppKit
import PDFKit
import PDFSave
import ReaderCore
import Testing
@testable import Lectern

/// M6: the annotation list reads only the pages that can hold a listed annotation; the About
/// panel, the licences and notices shipped in the app; and the headless self-check verify-dmg runs.
@MainActor
@Suite(.serialized, .noUI)
struct ReleaseTests {
    // MARK: The annotation list

    /// Every listed annotation, read the old way: every page.
    private func everyPage(_ harness: AnnotationHarness) -> [ObjectIdentifier] {
        (0..<harness.pdf.pageCount).flatMap { index in
            (harness.pdf.page(at: index)?.annotations ?? [])
                .filter { AnnotationKindName.isListed(subtype: $0.type ?? "") }
                .sorted { a, b in a.bounds.maxY != b.bounds.maxY ? a.bounds.maxY > b.bounds.maxY : a.bounds.minX < b.bounds.minX }
                .map(ObjectIdentifier.init)
        }
    }

    private func listed(_ harness: AnnotationHarness) -> [ObjectIdentifier] {
        harness.controller.annotationListCache = nil
        return harness.controller.annotationList.map { ObjectIdentifier($0.annotation) }
    }

    @Test func aHighlightOnAPageWithNoAnnotationsInTheFileIsListed() async throws {
        // A real paper: 420 links and nothing listed.
        let harness = try await AnnotationHarness(corpus: "arxiv-2310.12457v2")
        defer { harness.close() }
        let pages = try #require(harness.editor.pagesThatCanHoldListedAnnotations(), "the inspection has run")
        #expect(pages.isEmpty)
        #expect(listed(harness).isEmpty)

        let page = try #require(harness.pdf.page(at: 6))
        let line = try #require(page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine().first { ($0.string ?? "").count > 10 })
        let highlight = try #require(try harness.editor.addMarkup(.highlight, covering: line, color: .yellow).first)
        #expect(harness.editor.pagesThatCanHoldListedAnnotations() == [6])
        #expect(listed(harness) == [ObjectIdentifier(highlight)])
        #expect(listed(harness) == everyPage(harness))

        // Saved, it comes from the file's descriptors instead, and is still listed.
        try await harness.save()
        #expect(harness.editor.pagesThatCanHoldListedAnnotations() == [6])
        #expect(listed(harness) == [ObjectIdentifier(highlight)])

        // Undoing the add (a new unsaved delete) takes it off the list.
        harness.undo.undo()
        #expect(listed(harness).isEmpty)
        #expect(everyPage(harness).isEmpty)
    }

    @Test(arguments: ["third-party-annots", "acroform-filled", "nasa-tm-2020-220520"])
    func theListIsWhatReadingEveryPageGives(_ name: String) async throws {
        let harness = try await AnnotationHarness(corpus: name)
        defer { harness.close() }
        #expect(harness.editor.pagesThatCanHoldListedAnnotations() != nil)
        #expect(listed(harness) == everyPage(harness))
    }

    @Test func anUnreadableFileFallsBackToReadingEveryPage() async throws {
        // Encrypted: the inspection can't read its annotations, so every page is read.
        let harness = try await AnnotationHarness(corpus: "encrypted-aes256-owner-only")
        defer { harness.close() }
        #expect(harness.editor.pagesThatCanHoldListedAnnotations() == nil)
        #expect(listed(harness) == everyPage(harness))
    }

    // MARK: Search on a long document

    /// PDFKit posts a notification per match and per page; on a long document they flood the main
    /// queue, and an update queued behind them with `asyncAfter` arrived only when the search ended
    /// (found by the M6 performance tests: 7.5 s of an empty list on the 3,270-page manual). The
    /// list must show results while the search is still running.
    @Test func resultsReachTheListWhileALongSearchRuns() throws {
        let harness = try NavigationHarness(FixturePDF.prose(pages: 1500))
        defer { harness.close() }
        harness.controller.startSearch("reading")
        let search = try #require(harness.controller.search)
        let seen = MainThreadMeter()
        let update = search.onChange
        let start = ProcessInfo.processInfo.systemUptime
        search.onChange = {
            if seen.firstShown == nil, search.isSearching, !search.results.isEmpty {
                seen.firstShown = ProcessInfo.processInfo.systemUptime - start
            }
            update?()
        }
        let end = Date().addingTimeInterval(120)
        while search.isSearching, Date() < end { Spin.runLoop(0.005) }
        let total = ProcessInfo.processInfo.systemUptime - start
        #expect(!search.isSearching)
        #expect(search.results.count == 1500 * 30)
        let shown = try #require(seen.firstShown, "no results were shown before the search ended (\(total) s)")
        #expect(shown < total / 2, "first shown after \(shown) s of \(total) s")
    }

    // MARK: About, licences, acknowledgements

    @Test func theAboutPanelNamesVersionSourceLicenceAndNoTelemetry() throws {
        let options = AboutPanel.options()
        #expect(options[.applicationName] as? String == "Lectern")
        let version = try #require(options[.applicationVersion] as? String)
        #expect(version == Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        #expect(version == "1.0.0")
        let credits = try #require(options[.credits] as? NSAttributedString)
        #expect(credits.string.contains("No telemetry"))
        #expect(credits.string.contains("github.com/ronimoe/pdf-reader"))
        #expect(credits.string.contains("GNU General Public License, version 3"))
        var linked: URL?
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in linked = linked ?? value as? URL }
        #expect(linked == AppResources.sourceRepository)
        let copyright = try #require(Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String)
        #expect(copyright.contains("Copyright ©") && copyright.contains("GPL"))
    }

    @Test func theLicenceNoticesAndLimitationsShipInTheApp() throws {
        let licence = try #require(AppResources.text("LICENSE"))
        #expect(licence.contains("GNU GENERAL PUBLIC LICENSE") && licence.contains("Version 3, 29 June 2007"))
        let notices = try #require(AppResources.text("Acknowledgements.txt"))
        // Sparkle's MIT licence and copyright notice, and those of the code it bundles.
        for needle in ["Sparkle 2.10.1", "Copyright (c) 2006-2013 Andy Matuschak.", "Permission is hereby granted, free of charge",
                       "bsdiff", "sais-lite", "orlp/ed25519", "SUSignatureVerifier"] {
            #expect(notices.contains(needle), "missing: \(needle)")
        }
        let limitations = try #require(AppResources.text("known-limitations.md"))
        #expect(limitations.contains("Forms are read-only"))
    }

    @Test func theHelpMenuOpensEachTextWithoutShowingIt() throws {
        let help = try #require(MainMenu.make().items.first { $0.title == "Help" }?.submenu)
        let actions = help.items.compactMap(\.action)
        #expect(actions.contains(#selector(AppDelegate.showLicence(_:))))
        #expect(actions.contains(#selector(AppDelegate.showAcknowledgements(_:))))
        #expect(actions.contains(#selector(AppDelegate.showKnownLimitations(_:))))
        let about = try #require(MainMenu.make().items.first?.submenu?.items.first)
        #expect(about.action == #selector(AppDelegate.showAbout(_:)))
        for (title, resource, needle) in [("Licence", "LICENSE", "GNU GENERAL PUBLIC LICENSE"),
                                          ("Acknowledgements", "Acknowledgements.txt", "Andy Matuschak"),
                                          ("Known Limitations", "known-limitations.md", "Known limitations")] {
            let controller = TextDocumentWindowController(title: title, resource: resource)
            #expect(controller.window?.title == title)
            #expect(controller.textView.string.contains(needle))
            #expect(!controller.textView.isEditable)
            #expect(controller.window?.isVisible == false)
        }
    }

    // MARK: The headless self-check

    @Test func theSelfCheckPassesItsEngineAndResourceChecksInTheTestHost() {
        let checks = SelfCheck.run(bundle: .main)
        func check(_ name: String) -> SelfCheck.Check? { checks.first { $0.name == name } }
        for name in ["bundle", "updates-opt-in", "document-type", "resource LICENSE", "resource Acknowledgements.txt",
                     "resource known-limitations.md", "sandbox", "pdfkit", "writer"] {
            #expect(check(name)?.passed == true, "\(name): \(check(name)?.detail ?? "not run")")
        }
        // The test host is a Debug build with get-task-allow, so that check runs but can't pass here;
        // verify-dmg runs the whole check on the Release build.
        #expect(check("no-get-task-allow") != nil)
    }

    @Test func withoutTheArgumentTheSelfCheckDoesNothing() {
        // Returning at all is the point: with the argument it would exit the process.
        SelfCheck.runIfRequested(arguments: ["Lectern", "-ApplePersistenceIgnoreState", "YES"])
    }

    @Test func theSelfCheckEngineCatchesABlankPage() throws {
        let data = try #require(SelfCheck.makePDF(text: "x"))
        let document = try #require(PDFDocument(data: data))
        // Page 2 is empty: the ink check must say so.
        #expect(!SelfCheck.drawsInk(try #require(document.page(at: 1))))
        #expect(SelfCheck.drawsInk(try #require(document.page(at: 0))))
    }
}
