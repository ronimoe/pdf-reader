import AppKit
import PDFKit
import PDFSave
import Persistence
import ReaderCore
import ReaderKit
import Testing
@testable import Lectern

/// Two squares, "alpha" and "beta". The swapped version keeps their places but exchanges their
/// object numbers, so a journal's `.delete(6 0 R)` that meant alpha would hit beta.
nonisolated enum TwoSquaresFixture {
    static let alphaRect = "[72 600 200 700]"
    static let betaRect = "[300 600 450 700]"

    static func make(swapped: Bool) -> Data {
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R 7 0 R] >>"
        objects[4] = SpikeRawPDF.stream("BT /F1 14 Tf 72 740 Td (Two squares on this page) Tj ET\n")
        objects[5] = SpikeRawPDF.helvetica
        let alpha = "<< /Type /Annot /Subtype /Square /Rect \(alphaRect) /C [1 0 0] /Contents (alpha) >>"
        let beta = "<< /Type /Annot /Subtype /Square /Rect \(betaRect) /C [0 0 1] /Contents (beta) >>"
        objects[6] = swapped ? beta : alpha
        objects[7] = swapped ? alpha : beta
        return SpikeRawPDF.build(objects: objects, root: 1).data
    }
}

/// A highlight with no `/C`, and a page with a form widget but no AcroForm `/Fields`.
nonisolated enum ReviewFixtures {
    static func highlightWithoutColor() -> Data {
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R] >>"
        objects[4] = SpikeRawPDF.stream("BT /F1 14 Tf 72 700 Td (Highlighted words without a colour) Tj ET\n")
        objects[5] = SpikeRawPDF.helvetica
        objects[6] = "<< /Type /Annot /Subtype /Highlight /Rect [72 696 340 716] /QuadPoints [72 716 340 716 72 696 340 696] >>"
        return SpikeRawPDF.build(objects: objects, root: 1).data
    }

    static func widgetWithoutFields() -> Data {
        var objects: [Int: String] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R] /Count 2 >>"
        objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
        objects[4] = SpikeRawPDF.stream("BT /F1 14 Tf 72 700 Td (Page one has no widget) Tj ET\n")
        objects[5] = SpikeRawPDF.helvetica
        objects[8] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R] >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R 8 0 R] /Count 2 >>"
        objects[6] = "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Ada) /Rect [72 500 300 524] /F 4 >>"
        return SpikeRawPDF.build(objects: objects, root: 1).data
    }
}

/// Records NSDocument's save and close callbacks.
final class SaveCallbackRecorder: NSObject {
    private(set) var saves: [Bool] = []
    private(set) var closes: [Bool] = []
    @objc func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) { saves.append(didSave) }
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { closes.append(shouldClose) }
}

extension M4Tests {
    /// The fixes from the M4b review (PR #12), each with a test that failed before it.
    @MainActor @Suite struct ReviewFixes {
        // MARK: No UI in tests

        @Test func theUITripwireIsInstalledBeforeAnyTest() throws {
            #expect(UITripwire.shared.isInstalled, "LecternTestPrincipal didn't run")
        }

        // MARK: 1. A reload while the journal question is open

        func crashOnAlpha(_ folder: TemporaryFolder) async throws -> (url: URL, store: DocumentStateStore, journal: AnnotationJournal) {
            let url = try folder.write(TwoSquaresFixture.make(swapped: false), to: "squares.pdf")
            let first = try await AnnotationHarness(file: url, folder: folder)
            let alpha = try #require(first.pdf.page(at: 0)?.annotations.first { $0.contents == "alpha" })
            try first.editor.delete(alpha)
            #expect(first.editor.pending.changes == [.delete(ObjectRef(6))])
            first.journal.flush(try #require(first.controller.storedDocumentID))
            first.abandon()
            return (url, first.store, first.journal)
        }

        @Test(arguments: [JournalChoice.restore, .keep])
        func aReloadWhileAskingNeverAppliesOrLosesTheJournal(answer: JournalChoice) async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crashOnAlpha(folder)
            let second = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.store, journal: crashed.journal,
                                                     staleJournalChoice: .keep, defersJournalOffer: true)
            defer { second.close() }
            #expect(second.presenter.journalOffers == [1])
            // Another app rewrites the file, renumbering the squares, while the question is open.
            let swapped = TwoSquaresFixture.make(swapped: true)
            try swapped.write(to: crashed.url)
            #expect(await second.document.reloadFromDiskIfChanged())
            await second.waitForInspection()
            second.presenter.answerJournal(answer)
            let page = try #require(second.pdf.page(at: 0))
            #expect(Set(page.annotations.compactMap(\.contents)) == ["alpha", "beta"], "nothing was deleted")
            #expect(second.editor.pending.isEmpty)
            if answer == .restore {
                // The changes no longer fit: explained as stale, and kept.
                #expect(second.presenter.staleJournalExplanations == [false])
            }
            let id = try #require(second.controller.storedDocumentID)
            guard case .mismatched(let kept) = second.journal.lookup(id, currentSHA256: JournalEntry.hash(of: swapped)) else {
                Issue.record("the journal must survive as a kept journal")
                return
            }
            #expect(kept.changes == [.delete(ObjectRef(6))])
        }

        @Test func newChangesWhileAskingKeepTheJournal() async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crashOnAlpha(folder)
            let second = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.store, journal: crashed.journal,
                                                     defersJournalOffer: true)
            defer { second.close() }
            let beta = try #require(second.pdf.page(at: 0)?.annotations.first { $0.contents == "beta" })
            try second.editor.setContents("edited first", of: beta)
            let id = try #require(second.controller.storedDocumentID)
            second.journal.flush(id)
            second.presenter.answerJournal(.restore)
            #expect(second.editor.pending.count == 1, "the journal isn't replayed over new changes")
            // Set aside before the question, so the new changes' journal didn't replace it.
            let kept = try FileManager.default.contentsOfDirectory(at: second.journal.directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(".kept-") }
            #expect(kept.count == 1)
        }

        // MARK: 5. Restore and Discard act only on the journal that was offered

        @Test(arguments: [JournalChoice.discard, .restore])
        func anOlderKeptJournalSurvivesTheAnswerAboutTheLiveOne(answer: JournalChoice) async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crashOnAlpha(folder)
            let id = crashed.store.open(url: crashed.url, data: try Data(contentsOf: crashed.url), pageCount: 1).id
            // An older journal the user kept earlier, never shown in this session.
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let older = JournalEntry(originalSHA256: "an-older-version", changes: [.delete(ObjectRef(7))])
            let olderFile = crashed.journal.directory.appending(path: "\(id.uuidString).kept-1.json")
            try encoder.encode(older).write(to: olderFile)

            let second = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.store, journal: crashed.journal, journalChoice: answer)
            #expect(second.presenter.journalOffers == [1])
            #expect(FileManager.default.fileExists(atPath: olderFile.path), "the older kept journal was deleted unseen")
            if answer == .restore { try await second.save() }
            second.close()
            // It is offered on the next open.
            let third = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.store, journal: crashed.journal, staleJournalChoice: .keep)
            defer { third.close() }
            #expect(third.presenter.staleJournalExplanations == [false])
            #expect(FileManager.default.fileExists(atPath: olderFile.path))
        }

        // MARK: 2 and 3. Never save over a protected or changed original

        @Test func saveAsOntoTheSignedOriginalIsRefused() async throws {
            let harness = try await AnnotationHarness(corpus: "signed-approval")
            defer { harness.close() }
            let original = harness.fileBytes
            try harness.highlight("quick brown fox")
            await #expect(throws: (any Error).self) { try await harness.save(to: harness.fileURL, .saveAsOperation) }
            await #expect(throws: (any Error).self) { try await harness.save(to: harness.fileURL, .saveToOperation) }
            // The same file under another path (a hard link) is still the same file.
            let link = harness.folder.url.appending(path: "link.pdf")
            try FileManager.default.linkItem(at: harness.fileURL, to: link)
            await #expect(throws: (any Error).self) { try await harness.save(to: link, .saveAsOperation) }
            #expect(harness.fileBytes == original)
            #expect(harness.document.isDocumentEdited)
            // The copy route suggests a name that isn't the original's.
            #expect(harness.document.copySuggestedName == "signed-approval (annotated).pdf")
        }

        @Test func saveAsOntoAnInPlaceFileItselfStillWorks() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            try harness.highlight("quick brown fox")
            try await harness.save(to: harness.fileURL, .saveAsOperation)
            #expect(try SavedFile(harness.fileBytes).lecternDescriptors.count == 1)
        }

        @Test func b7SaveACopyOntoTheChangedFileIsRefused() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            harness.presenter.changedFileChoice = .saveCopy
            harness.presenter.copyDestination = harness.fileURL
            try harness.highlight("quick brown fox")
            let other = try IncrementalWriter().saveInPlace(original: harness.fileBytes, changes: [
                .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 50, y: 50), contents: "from another app")),
            ]).data
            try other.write(to: harness.fileURL)
            await harness.document.reloadFromDiskIfChanged()
            await harness.settle { !harness.controller.isAskingAboutChangedFile }
            #expect(harness.presenter.copyDestinationRequests == ["classic-xref (annotated).pdf"])
            #expect(harness.fileBytes == other, "the other app's version was overwritten")
            #expect(harness.editor.pending.count == 1)
            #expect(harness.openedCopies.isEmpty)
            // The refusal is reported through the presenter, never as a real alert.
            #expect(harness.presenter.presentedErrors == ["The file changed on disk since Lectern opened it."])
        }

        // MARK: 4. NSDocument's save delegate always gets an answer

        @Test func changedOnDiskAndRefusedSavesAnswerTheDelegate() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let recorder = SaveCallbackRecorder()
            let didSave = #selector(SaveCallbackRecorder.document(_:didSave:contextInfo:))
            try harness.highlight("quick brown fox")
            let other = try IncrementalWriter().saveInPlace(original: harness.fileBytes, changes: [
                .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 50, y: 50), contents: "x")),
            ]).data
            try other.write(to: harness.fileURL)
            harness.document.save(withDelegate: recorder, didSave: didSave, contextInfo: nil)
            #expect(recorder.saves == [false])
            #expect(harness.presenter.changedFileQuestions == 1)

            let folder = try TemporaryFolder()
            let url = try folder.write(try Corpus.data("encrypted-r5"), to: "encrypted.pdf")
            let encrypted = try await AnnotationHarness(file: url, folder: folder, password: "user-pass")
            defer { encrypted.close() }
            encrypted.document.save(withDelegate: recorder, didSave: didSave, contextInfo: nil)
            #expect(recorder.saves == [false, false])
            #expect(encrypted.presenter.refusals == [.cannotSave(.encrypted(.revision(version: 5, revision: 5)))])
        }

        // MARK: 6. Undoing a recolour of an annotation without /C

        @Test func undoingARecolourWithoutAnyColourInTheFileLeavesNothingToSave() async throws {
            let harness = try await AnnotationHarness(data: ReviewFixtures.highlightWithoutColor())
            defer { harness.close() }
            let highlight = try #require(harness.pdf.page(at: 0)?.annotations.first { $0.type == "Highlight" })
            let shown = highlight.color
            try harness.editor.setColor(AnnotationColorPreset.green.pdfColor, of: highlight)
            #expect(harness.editor.pending.count == 1)
            harness.undo.undo()
            #expect(harness.editor.pending.isEmpty, "\(harness.editor.pending.changes)")
            #expect(!harness.document.isDocumentEdited)
            #expect(highlight.color == shown)
            harness.undo.redo()
            #expect(harness.editor.pending.count == 1)
        }

        // MARK: 7. A rescued deleted file saves in place again

        @Test func saveAsAfterTheFileWasDeletedMakesTheCopyTheDocument() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            harness.document.fileDidGoAway()
            try harness.highlight("quick brown fox")
            guard case .copy = harness.document.saveRoute else {
                Issue.record("a removed file saves as a copy")
                return
            }
            let rescued = harness.folder.url.appending(path: "rescued.pdf")
            try await harness.save(to: rescued, .saveAsOperation)
            #expect(!harness.document.fileWasRemoved)
            try harness.highlight("lazy dog", kind: .underline)
            #expect(harness.document.saveRoute == .inPlace)
            #expect(harness.controller.notice.message == "Saved" || harness.controller.notice.message == nil)
        }

        // MARK: 8. Forms: the mechanism, against a control that shows the risk is real

        @Test func tabNeverReachesPDFKitInAFormAndAStockViewWouldEditOnClick() async throws {
            let harness = try await AnnotationHarness(corpus: "acroform-filled")
            defer { harness.close() }
            // Tab, sent through the window to the page, leaves for the next control. This
            // doesn't pin the Tab handling: with synthesized events, PDFKit passes Tab on the same
            // way (a mutant without it survives), so whether a real keyboard reaches a field
            // stays [verify] (architecture §4.3).
            #expect(Self.tabLeavesThePage(harness))

            // Positive control: the same click on the same field edits it in a stock PDFView.
            let data = try Corpus.data("acroform-filled")
            let stock = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
            let stockHost = OffscreenHost(content: stock)
            defer { stockHost.close() }
            let stockDocument = try #require(PDFDocument(data: data))
            stock.spikeLoad(stockDocument, mode: .singlePage)
            stockHost.window.makeFirstResponder(stock)
            let field = try #require(stockDocument.page(at: 0)?.annotations.first { $0.type == "Widget" && $0.widgetFieldType == .text })
            Synth.click(at: stock.windowPoint(centerOf: field), in: stockHost.window)
            Spin.runLoop(0.2)
            let stockResponder = stockHost.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            // On macOS 27 only window-dispatched clicks edit (M0b Q3): that control is
            // `realClicksEditAStockViewButNeverTheReader`.
            if M0bSpikes.Q3Forms.directClicksReachWidgets {
                #expect(stockResponder == "PDFTextWidgetTextView", "control: a stock view starts editing (\(stockResponder))")
            } else {
                #expect(stockResponder == "PDFView", "macOS 27: a direct click edits nothing (\(stockResponder))")
            }

            let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
            let readerHost = OffscreenHost(content: reader)
            defer { readerHost.close() }
            let readerDocument = try #require(PDFDocument(data: data))
            reader.spikeLoad(readerDocument, mode: .singlePage)
            readerHost.window.makeFirstResponder(reader)
            let readerField = try #require(readerDocument.page(at: 0)?.annotations.first { $0.type == "Widget" && $0.widgetFieldType == .text })
            Synth.click(at: reader.windowPoint(centerOf: readerField), in: readerHost.window)
            Spin.runLoop(0.2)
            #expect(readerHost.window.firstResponder === reader)
            #expect(!readerField.isReadOnly)
        }

        /// The control with clicks and keys dispatched through the window, as a person's are: the
        /// only kind macOS 27's PDFView acts on (M0b Q3). AppKit drops those unless the app is
        /// active, and the test host is never activated, so this runs only where it already is:
        /// CI's runners, on macOS 26 and 27.
        @Test(.enabled("only where the test host is already the active app (CI)") { await MainActor.run { NSApp.isActive } })
        func realClicksEditAStockViewButNeverTheReader() throws {
            for reading in [false, true] {
                let frame = NSRect(x: 0, y: 0, width: 700, height: 900)
                let view = reading ? ReaderPDFView(frame: frame) : PDFView(frame: frame)
                let host = OffscreenHost(content: view)
                defer { host.close() }
                let document = try #require(PDFDocument(data: SpikeFixtures.form()))
                view.spikeLoad(document, mode: .singlePage)
                host.window.pretendsKey = false
                host.window.makeKeyAndOrderFront(nil)
                host.window.makeFirstResponder(view)
                Spin.runLoop(0.2)
                #expect(host.window.isKeyWindow)
                let fields = try #require(document.page(at: 0)?.annotations)
                let name = try #require(fields.first { $0.fieldName == "name" })
                let agree = try #require(fields.first { $0.fieldName == "agree" })
                Synth.windowClick(at: view.windowPoint(centerOf: name), in: host.window)
                let responder = host.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                Synth.windowKey("Z", keyCode: 6, in: host.window)
                Synth.windowClick(at: view.windowPoint(centerOf: agree), in: host.window)
                if reading {
                    #expect(host.window.firstResponder === view)
                    #expect(name.widgetStringValue == "Alice")
                    #expect(agree.buttonWidgetState == .offState)
                } else {
                    #expect(responder == "PDFTextWidgetTextView", "control: a stock view starts editing (\(responder))")
                    #expect(name.widgetStringValue == "AliceZ")
                    #expect(agree.buttonWidgetState == .onState)
                }
            }
        }

        /// macOS 27's PDFView handles clicks with gesture recognizers, except in a subclass that
        /// overrides the mouse handlers: that keeps PDFKit's mouse-down path (M0b Q3), which the
        /// reader's link and form interception relies on. This fails if PDFKit ever gives the
        /// reader, its document view or its pages those recognizers.
        @Test func theReaderStaysOnPDFKitsMouseDownPath() throws {
            func recognizers(in root: PDFView) -> [String] {
                var found: [String] = []
                func walk(_ view: NSView) {
                    let name = String(describing: type(of: view))
                    if view === root || name.hasPrefix("PDFDocument") || name.hasPrefix("PDFPage") {
                        found += view.gestureRecognizers
                            .filter { !ReaderPDFView.isImmediateAction($0) }
                            .map { "\(name): \(type(of: $0))" }
                    }
                    view.subviews.forEach(walk)
                }
                walk(root)
                return found
            }
            for reading in [true, false] {
                let frame = NSRect(x: 0, y: 0, width: 700, height: 900)
                let view = reading ? ReaderPDFView(frame: frame) : PDFView(frame: frame)
                let host = OffscreenHost(content: view)
                defer { host.close() }
                view.spikeLoad(try #require(PDFDocument(data: SpikeFixtures.form())), mode: .singlePage)
                let found = recognizers(in: view)
                if reading {
                    #expect(found.isEmpty, "\(found)")
                } else if #available(macOS 27, *) {
                    // The control: a stock view on macOS 27 has them.
                    #expect(found.contains { $0.hasSuffix("NSClickGestureRecognizer") }, "\(found)")
                } else {
                    #expect(found.isEmpty, "macOS 26 has none: \(found)")
                }
            }
        }

        /// Sends Tab to the page through the window, with a text field as the next key view, and
        /// says whether focus left the page.
        static func tabLeavesThePage(_ harness: AnnotationHarness) -> Bool {
            let probe = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
            harness.window.contentView?.addSubview(probe)
            defer { probe.removeFromSuperview() }
            harness.view.nextKeyView = probe
            harness.window.makeFirstResponder(harness.view)
            Synth.key("\t", keyCode: 48, in: harness.window)
            return harness.window.firstResponder !== harness.view
        }

        // MARK: 9. Widgets without AcroForm fields

        @Test func aWidgetWithoutAcroFormFieldsCountsAsAForm() async throws {
            let harness = try await AnnotationHarness(data: ReviewFixtures.widgetWithoutFields())
            defer { harness.close() }
            #expect(harness.view.documentHasFormFields)
            #expect(harness.controller.formInfoLine.message == ReaderWindowController.formFieldsMessage)
        }
    }
}

/// Answers NSDocument's error-presentation callback.
final class PresentCallbackRecorder: NSObject {
    private(set) var presented: [Bool] = []
    @objc func didPresentError(withRecovery didRecover: Bool, contextInfo: UnsafeMutableRawPointer?) { presented.append(didRecover) }
}

/// An error whose recovery attempter AppKit's alert would run.
nonisolated final class RecoveryAttempter: NSObject {
    @objc override func attemptRecovery(fromError error: any Error, optionIndex recoveryOptionIndex: Int) -> Bool { true }
}

extension M4Tests {
    /// The second review round (ef5230c), each with a test that fails without its fix.
    @MainActor @Suite struct ReviewRound2 {
        // 1. A reload before the journal check never deletes the journal.
        @Test func aReloadBeforeTheJournalCheckKeepsAndOffersIt() async throws {
            let folder = try TemporaryFolder()
            let url = try folder.write(TwoSquaresFixture.make(swapped: false), to: "squares.pdf")
            let first = try await AnnotationHarness(file: url, folder: folder)
            let alpha = try #require(first.pdf.page(at: 0)?.annotations.first { $0.contents == "alpha" })
            try first.editor.delete(alpha)
            let id = try #require(first.controller.storedDocumentID)
            first.journal.flush(id)
            first.abandon()

            let second = try await AnnotationHarness(file: url, folder: folder, store: first.store, journal: first.journal,
                                                     staleJournalChoice: .keep, inspectionDelay: .seconds(1))
            defer { second.close() }
            #expect(second.presenter.journalOffers.isEmpty && second.presenter.staleJournalExplanations.isEmpty, "the check hasn't run yet")
            // The file is rewritten while the check is still running.
            let swapped = TwoSquaresFixture.make(swapped: true)
            try swapped.write(to: url)
            #expect(await second.document.reloadFromDiskIfChanged())
            await second.waitForInspection()
            #expect(second.presenter.staleJournalExplanations == [false], "offered as no longer fitting")
            guard case .mismatched(let kept) = second.journal.lookup(id, currentSHA256: JournalEntry.hash(of: swapped)) else {
                Issue.record("the crash journal was deleted unseen")
                return
            }
            #expect(kept.changes == [.delete(ObjectRef(6))])
            #expect(Set(second.pdf.page(at: 0)?.annotations.compactMap(\.contents) ?? []) == ["alpha", "beta"])
        }

        // 2. A symbolic link to the original is the original.
        @Test func saveAsThroughASymbolicLinkToTheSignedOriginalIsRefused() async throws {
            let folder = try TemporaryFolder()
            let target = try folder.write(try Corpus.data("signed-approval"), to: "signed.pdf")
            let link = folder.url.appending(path: "link.pdf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let original = try Data(contentsOf: target)
            // Opened through the link, saved onto the target; then the other way round.
            let viaLink = try await AnnotationHarness(file: link, folder: folder)
            try viaLink.highlight("quick brown fox")
            await #expect(throws: (any Error).self) { try await viaLink.save(to: target, .saveAsOperation) }
            viaLink.close()
            let direct = try await AnnotationHarness(file: target, folder: folder)
            defer { direct.close() }
            try direct.highlight("quick brown fox")
            await #expect(throws: (any Error).self) { try await direct.save(to: link, .saveAsOperation) }
            #expect(try Data(contentsOf: target) == original)
        }

        // 3. Restore journals the changes again before the offered file goes.
        @Test func restoreJournalsTheChangesBeforeDeletingTheOfferedFile() async throws {
            let folder = try TemporaryFolder()
            let url = try folder.write(TwoSquaresFixture.make(swapped: false), to: "squares.pdf")
            let first = try await AnnotationHarness(file: url, folder: folder)
            let alpha = try #require(first.pdf.page(at: 0)?.annotations.first { $0.contents == "alpha" })
            try first.editor.delete(alpha)
            let id = try #require(first.controller.storedDocumentID)
            first.journal.flush(id)
            first.abandon()
            // The harness journal debounces for 60 s: only an explicit flush writes it in time.
            let second = try await AnnotationHarness(file: url, folder: folder, store: first.store, journal: first.journal)
            defer { second.close() }
            #expect(second.editor.pending.changes == [.delete(ObjectRef(6))])
            let hash = try #require(second.editor.originalSHA256)
            guard case .matching(let live) = second.journal.read(second.journal.url(for: id), currentSHA256: hash) else {
                Issue.record("a crash right after Restore would lose the changes")
                return
            }
            #expect(live.changes == second.editor.pending.changes)
        }

        // 4. Error presentation keeps AppKit's behaviour.
        @Test func aCancelledSaveShowsNothingAndStillAnswers() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let recorder = PresentCallbackRecorder()
            let cancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            harness.document.presentError(cancelled, modalFor: harness.window, delegate: recorder,
                                          didPresent: #selector(PresentCallbackRecorder.didPresentError(withRecovery:contextInfo:)), contextInfo: nil)
            #expect(harness.presenter.presentedErrors.isEmpty)
            #expect(recorder.presented == [false])
        }

        @Test func anErrorWithRecoveryGoesToAppKit() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            let error = NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Recoverable",
                NSLocalizedRecoveryOptionsErrorKey: ["Try Again", "Cancel"],
                NSRecoveryAttempterErrorKey: RecoveryAttempter(),
            ])
            let attempted = UITripwire.shared.expecting {
                harness.document.presentError(error, modalFor: harness.window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
            #expect(harness.presenter.presentedErrors.isEmpty)
            #expect(!attempted.isEmpty, "AppKit's own presentation (blocked by the tripwire)")
        }

        @Test func theSheetPresenterShowsOneAlert() throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            let attempted = UITripwire.shared.expecting {
                SheetPresenter().presentError(NSError(domain: "test", code: 2), on: window) {}
            }
            #expect(attempted.count == 1)
            #expect(attempted.first?.hasPrefix("NSAlert.beginSheetModal") == true)
        }

        // 6. Undo after a save is a new change, even back to "no colour".
        @Test func undoingARecolourAfterASaveIsANewChange() async throws {
            let harness = try await AnnotationHarness(data: ReviewFixtures.highlightWithoutColor())
            defer { harness.close() }
            let highlight = try #require(harness.pdf.page(at: 0)?.annotations.first { $0.type == "Highlight" })
            try harness.editor.setColor(AnnotationColorPreset.green.pdfColor, of: highlight)
            try await harness.save()
            harness.undo.undo()
            #expect(harness.editor.pending.count == 1)
            #expect(harness.document.isDocumentEdited)
        }

        // 7. The tripwire ends a blocked sheet with Cancel.
        @Test func aBlockedSheetStillFinishes() async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            var response: NSApplication.ModalResponse?
            UITripwire.shared.expecting {
                NSAlert().beginSheetModal(for: window) { response = $0 }
            }
            for _ in 0..<50 where response == nil { try await Task.sleep(for: .milliseconds(10)) }
            // No buttons: the implicit OK.
            #expect(response == .alertFirstButtonReturn)
        }

        // 8. The same-file check repeats when the bytes are written.
        @Test func theWriteChecksTheDestinationAgain() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            try harness.highlight("quick brown fox")
            // The save began while the file was unchanged; another app writes it before the write.
            harness.document.saveDestination = harness.fileURL
            let other = try IncrementalWriter().saveInPlace(original: harness.fileBytes, changes: [
                .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 50, y: 50), contents: "x")),
            ]).data
            try other.write(to: harness.fileURL)
            let temporary = harness.folder.url.appending(path: "temporary.pdf")
            #expect(throws: (any Error).self) {
                try harness.document.write(to: temporary, ofType: "com.adobe.pdf", for: .saveAsOperation, originalContentsURL: harness.fileURL)
            }
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            harness.document.saveDestination = nil
        }

        // 9. A touched file with the same bytes saves normally.
        @Test func aTouchedButUnchangedFileSavesWithoutAQuestion() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            try harness.highlight("quick brown fox")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: harness.fileURL.path)
            harness.document.save(nil)
            await harness.settle { !harness.document.isDocumentEdited }
            #expect(!harness.document.isDocumentEdited)
            #expect(try SavedFile(harness.fileBytes).lecternDescriptors.count == 1)
            #expect(harness.presenter.changedFileQuestions == 0)
        }
    }
}

extension M4Tests {
    /// The final review round (2441171), each with a test that fails without its fix.
    @MainActor @Suite struct ReviewRound3 {
        func crash(_ folder: TemporaryFolder) async throws -> (url: URL, first: AnnotationHarness, id: UUID) {
            let url = try folder.write(TwoSquaresFixture.make(swapped: false), to: "squares.pdf")
            let first = try await AnnotationHarness(file: url, folder: folder)
            let alpha = try #require(first.pdf.page(at: 0)?.annotations.first { $0.contents == "alpha" })
            try first.editor.delete(alpha)
            let id = try #require(first.controller.storedDocumentID)
            first.journal.flush(id)
            first.abandon()
            return (url, first, id)
        }

        // MAJOR 1: Save As before the check keeps the crash journal, which the original then offers.
        @Test func saveAsBeforeTheJournalCheckKeepsTheJournal() async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crash(folder)
            let second = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.first.store, journal: crashed.first.journal,
                                                     journalChoice: .keep, inspectionDelay: .seconds(1))
            #expect(second.presenter.journalOffers.isEmpty, "the check hasn't run yet")
            try await second.save(to: folder.url.appending(path: "copy.pdf"), .saveAsOperation)
            await second.waitForInspection()
            second.close()
            #expect(second.journal.lookup(crashed.id, currentSHA256: JournalEntry.hash(of: try Data(contentsOf: crashed.url))) != .none,
                    "the crash journal was deleted unseen")
            let third = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.first.store, journal: crashed.first.journal, journalChoice: .keep)
            defer { third.close() }
            #expect(third.presenter.journalOffers == [1])
        }

        // MAJOR 2: a Restore whose journal can't be written keeps the offered file.
        @Test func restoreKeepsTheOfferedFileWhenTheJournalCantBeWritten() async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crash(folder)
            let second = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.first.store, journal: crashed.first.journal,
                                                     defersJournalOffer: true)
            defer { second.close() }
            let kept = try FileManager.default.contentsOfDirectory(at: second.journal.directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(".kept-") }
            #expect(kept.count == 1)
            // A directory where the live journal goes: every write of it fails.
            try FileManager.default.createDirectory(at: second.journal.url(for: crashed.id), withIntermediateDirectories: false)
            second.presenter.answerJournal(.restore)
            #expect(second.editor.pending.count == 1, "restored on screen")
            #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "the only copy on disk was deleted")
        }

        @Test func restoreNeverDeletesTheLiveJournalItJustWrote() async throws {
            let folder = try TemporaryFolder()
            let crashed = try await crash(folder)
            let second = try await AnnotationHarness(file: crashed.url, folder: folder, store: crashed.first.store, journal: crashed.first.journal,
                                                     journalChoice: .discard)
            defer { second.close() }
            // The offered file is the live journal itself (setting it aside failed).
            let hash = try #require(second.editor.originalSHA256)
            let entry = JournalEntry(originalSHA256: hash, changes: [.delete(ObjectRef(6))])
            let live = second.journal.url(for: crashed.id)
            try JSONEncoder.isoDates.encode(entry).write(to: live)
            second.controller.restoreJournal(entry, from: JournalFile(url: live, lookup: .matching(entry)))
            #expect(second.editor.pending.changes == [.delete(ObjectRef(6))])
            guard case .matching(let written) = second.journal.read(live, currentSHA256: hash) else {
                Issue.record("Restore deleted the journal of the changes it restored")
                return
            }
            #expect(written.changes == second.editor.pending.changes)
        }

        // MINOR 3: a blocked alert answers as a person cancelling it would.
        @Test func aBlockedAlertAnswersWithItsCancelButton() throws {
            func alert(_ titles: [String]) -> NSAlert {
                let alert = NSAlert()
                titles.forEach { alert.addButton(withTitle: $0) }
                return alert
            }
            var responses: [NSApplication.ModalResponse] = []
            UITripwire.shared.expecting {
                responses.append(alert(["OK", "Cancel"]).runModal())
                responses.append(alert(["Save", "Cancel", "Don’t Save"]).runModal())
                responses.append(alert(["Restore", "Discard", "Keep"]).runModal())
                responses.append(alert([]).runModal())
            }
            #expect(responses == [.alertSecondButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn, .alertFirstButtonReturn])
        }

        // MINOR 4: the write-path recheck, through NSDocument's real save.
        @Test(arguments: [NSDocument.SaveOperationType.saveAsOperation, .saveToOperation])
        func aFileChangedDuringTheSaveIsNotOverwritten(operation: NSDocument.SaveOperationType) async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            try harness.highlight("quick brown fox")
            let other = try IncrementalWriter().saveInPlace(original: harness.fileBytes, changes: [
                .addNote(NewNote(pageIndex: 0, origin: PDFPoint(x: 50, y: 50), contents: "x")),
            ]).data
            // Unchanged when the save starts; another app writes the file before the bytes are.
            harness.document.willWriteForTesting = { [url = harness.fileURL] in try? other.write(to: url) }
            await #expect(throws: (any Error).self) { try await harness.save(to: harness.fileURL, operation) }
            harness.document.willWriteForTesting = nil
            #expect(harness.fileBytes == other)
            #expect(harness.editor.pending.count == 1)
        }

        // MINOR 6: a same-size rewrite with a new date is a change, however it looks.
        @Test func aSameSizeRewriteIsStillAChange() async throws {
            let harness = try await AnnotationHarness(corpus: "classic-xref")
            defer { harness.close() }
            try harness.highlight("quick brown fox")
            var rewritten = harness.fileBytes
            let marker = try #require(rewritten.range(of: Data("%%EOF".utf8), options: .backwards))
            rewritten.replaceSubrange(marker, with: Data("%%EOX".utf8))
            #expect(rewritten.count == harness.fileBytes.count && rewritten != harness.fileBytes)
            try rewritten.write(to: harness.fileURL)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: harness.fileURL.path)
            harness.document.save(nil)
            await harness.settle { harness.presenter.changedFileQuestions > 0 }
            #expect(harness.presenter.changedFileQuestions == 1)
            #expect(harness.fileBytes == rewritten)
            #expect(harness.editor.pending.count == 1)
        }
    }
}

extension JSONEncoder {
    static var isoDates: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
