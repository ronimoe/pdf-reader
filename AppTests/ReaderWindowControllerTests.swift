import AppKit
import PDFKit
import Persistence
import ReaderCore
import ReaderKit
import ReaderUI
import Testing
@testable import Lectern

/// Whether Edit ▸ Copy would be enabled for `view`, through AppKit's own
/// menu validation rather than a direct call.
@MainActor
private func isCopyEnabled(on view: NSView) -> Bool {
    let menu = NSMenu()
    let item = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    item.target = view
    menu.update()
    return item.isEnabled
}

/// Drives a reader window in-process, without showing it.
@MainActor
private struct Harness {
    let document: ReaderDocument
    let controller: ReaderWindowController
    let presenter = RecordingPresenter()
    let store: InMemoryPasswordStore

    init(_ data: Data, store: InMemoryPasswordStore = InMemoryPasswordStore()) throws {
        document = try ReaderDocument.loaded(data)
        self.store = store
        controller = ReaderWindowController(document: document, passwordStore: store, presenter: presenter)
        document.addWindowController(controller)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
    }

    var pdfView: ReaderPDFView { controller.pdfView }
    var lastPrompt: PasswordPromptModel? { presenter.prompts.last }

    func isEnabled(_ action: Selector) -> Bool {
        controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    func isChecked(_ action: Selector) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        _ = controller.validateMenuItem(item)
        return item.state == .on
    }

    func close() { document.close() }
}

@MainActor
@Suite struct ReaderWindowLayoutTests {
    @Test func windowIsTabbedFullScreenCapableAndTitled() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 2)))
        defer { harness.close() }
        let window = try #require(harness.controller.window)
        #expect(window.tabbingMode == .preferred)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.titleVisibility == .visible)
        #expect(window.toolbarStyle == .unifiedCompact)
        #expect(window.contentView === harness.pdfView)
        #expect(harness.controller.isShowingContent)
    }

    @Test func pageBackgroundIsNeverRecoloured() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 1)))
        defer { harness.close() }
        // Only the area behind the pages follows the appearance (Rule 4).
        #expect(harness.pdfView.backgroundColor == .underPageBackgroundColor)
    }

    @Test func pagesAndScrollingMapToDisplayModes() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 4)))
        defer { harness.close() }
        let controller = harness.controller
        #expect(harness.pdfView.displayMode == .singlePageContinuous)

        controller.scrollPageByPage(nil)
        #expect(harness.pdfView.displayMode == .singlePage)
        controller.showTwoPages(nil)
        #expect(harness.pdfView.displayMode == .twoUp)
        controller.scrollContinuously(nil)
        #expect(harness.pdfView.displayMode == .twoUpContinuous)
        controller.showSinglePage(nil)
        #expect(harness.pdfView.displayMode == .singlePageContinuous)

        #expect(harness.isChecked(#selector(ReaderWindowController.showSinglePage(_:))))
        #expect(!harness.isChecked(#selector(ReaderWindowController.showTwoPages(_:))))
        #expect(harness.isChecked(#selector(ReaderWindowController.scrollContinuously(_:))))
    }

    @Test func coverPageFollowsThePageLayoutHintAndCanBeOverridden() throws {
        let harness = try Harness(RawPDF.make(catalogExtras: "/PageLayout /TwoPageRight"))
        defer { harness.close() }
        harness.controller.showTwoPages(nil)
        #expect(harness.pdfView.displaysAsBook)
        #expect(harness.isChecked(#selector(ReaderWindowController.toggleCoverPage(_:))))

        harness.controller.toggleCoverPage(nil)
        #expect(!harness.pdfView.displaysAsBook)
        #expect(harness.controller.settings.coverPageAlone == false)
    }

    @Test func plainDocumentsDontPutTheCoverAlone() throws {
        let harness = try Harness(RawPDF.make())
        defer { harness.close() }
        harness.controller.showTwoPages(nil)
        #expect(!harness.pdfView.displaysAsBook)
        #expect(!harness.pdfView.displaysRTL)
        harness.controller.toggleCoverPage(nil)
        #expect(harness.pdfView.displaysAsBook)
    }

    @Test func rightToLeftFollowsTheDirectionPreferenceAndCanBeOverridden() throws {
        let harness = try Harness(RawPDF.make(catalogExtras: "/ViewerPreferences << /Direction /R2L >>"))
        defer { harness.close() }
        harness.controller.showTwoPages(nil)
        #expect(harness.pdfView.displaysRTL)
        harness.controller.toggleRightToLeft(nil)
        #expect(!harness.pdfView.displaysRTL)
    }

    @Test func coverAndDirectionAreOnlyOfferedForTwoPages() throws {
        let harness = try Harness(RawPDF.make())
        defer { harness.close() }
        #expect(!harness.isEnabled(#selector(ReaderWindowController.toggleCoverPage(_:))))
        #expect(!harness.isEnabled(#selector(ReaderWindowController.toggleRightToLeft(_:))))
        harness.controller.showTwoPages(nil)
        #expect(harness.isEnabled(#selector(ReaderWindowController.toggleCoverPage(_:))))
        #expect(harness.isEnabled(#selector(ReaderWindowController.toggleRightToLeft(_:))))
    }

    // MARK: Rotation (B9)

    @Test func rotateLeftAndRightTurnEveryPageWithoutTouchingTheBytes() throws {
        let data = RawPDF.make(pageRotations: [0, 90])
        let harness = try Harness(data)
        defer { harness.close() }
        let pdf = try #require(harness.document.pdfDocument)

        harness.controller.rotateDocumentRight(nil)
        #expect(pdf.page(at: 0)?.rotation == 90)
        #expect(pdf.page(at: 1)?.rotation == 180)
        harness.controller.rotateDocumentLeft(nil)
        harness.controller.rotateDocumentLeft(nil)
        #expect(pdf.page(at: 0)?.rotation == 270)
        #expect(pdf.page(at: 1)?.rotation == 0)
        #expect(harness.controller.settings.rotation == 270)

        #expect(harness.document.originalRotation(ofPageAt: 0) == 0)
        #expect(harness.document.originalRotation(ofPageAt: 1) == 90)
        #expect(harness.document.originalData == data)
    }
}

@MainActor
@Suite struct ReaderWindowZoomTests {
    @Test func zoomCommandsStepAndActualSizeIsOne() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 2)))
        defer { harness.close() }
        let controller = harness.controller

        controller.zoomToActualSize(nil)
        #expect(harness.pdfView.scaleFactor == 1)
        #expect(harness.isChecked(#selector(ReaderWindowController.zoomToActualSize(_:))))
        controller.increaseZoom(nil)
        #expect(abs(harness.pdfView.scaleFactor - 1.1) < 0.001)
        #expect(controller.settings.zoom == .scale(1.1))
        controller.decreaseZoom(nil)
        controller.decreaseZoom(nil)
        #expect(abs(harness.pdfView.scaleFactor - 0.9) < 0.001)
        #expect(!harness.isChecked(#selector(ReaderWindowController.zoomToActualSize(_:))))
    }

    @Test func fitWidthFillsTheWidthAndSurvivesResizes() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 3)))
        defer { harness.close() }
        let view = harness.pdfView
        harness.controller.zoomToFitWidth(nil)
        expectRowWidthMatchesVisibleWidth(view)
        let narrowScale = view.scaleFactor

        harness.controller.window?.setContentSize(NSSize(width: 1200, height: 600))
        #expect(view.scaleFactor > narrowScale * 1.3)
        expectRowWidthMatchesVisibleWidth(view)
        #expect(harness.controller.settings.zoom == .fitWidth)
        #expect(harness.isChecked(#selector(ReaderWindowController.zoomToFitWidth(_:))))
    }

    @Test func fitWidthCoversBothPagesInTwoUp() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 4)))
        defer { harness.close() }
        harness.controller.zoomToFitWidth(nil)
        let singleScale = harness.pdfView.scaleFactor
        harness.controller.showTwoPages(nil)
        #expect(harness.pdfView.scaleFactor < singleScale * 0.6)
        expectRowWidthMatchesVisibleWidth(harness.pdfView)
    }

    @Test func fitPageShowsTheWholePageAndSurvivesResizes() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 3)))
        defer { harness.close() }
        let view = harness.pdfView
        harness.controller.zoomToFitPage(nil)
        expectWholePageVisible(view)

        harness.controller.window?.setContentSize(NSSize(width: 800, height: 1100))
        expectWholePageVisible(view)
        #expect(harness.controller.settings.zoom == .fitPage)
    }

    @Test func fitWidthRefitsAfterRotation() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 2)))
        defer { harness.close() }
        harness.controller.zoomToFitWidth(nil)
        let portrait = harness.pdfView.scaleFactor
        harness.controller.rotateDocumentRight(nil)
        // A landscape page is wider, so it fits at a smaller scale.
        #expect(harness.pdfView.scaleFactor < portrait * 0.9)
        expectRowWidthMatchesVisibleWidth(harness.pdfView)
    }

    @Test func userZoomBecomesAFixedScale() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 2)))
        defer { harness.close() }
        harness.controller.zoomToFitWidth(nil)
        // What a pinch does: PDFKit changes the scale and posts the notification.
        harness.pdfView.scaleFactor = 2
        #expect(harness.controller.settings.zoom == .scale(2))
        harness.controller.window?.setContentSize(NSSize(width: 1200, height: 600))
        #expect(harness.pdfView.scaleFactor == 2)
    }

    private func expectRowWidthMatchesVisibleWidth(_ view: ReaderPDFView, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let page = view.document?.page(at: 0) else {
            Issue.record("no page", sourceLocation: sourceLocation)
            return
        }
        let row = view.rowSize(for: page)
        #expect(abs(row.width - view.visibleSize.width) < 2, "row \(row.width) vs visible \(view.visibleSize.width)", sourceLocation: sourceLocation)
    }

    private func expectWholePageVisible(_ view: ReaderPDFView, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let page = view.document?.page(at: 0) else {
            Issue.record("no page", sourceLocation: sourceLocation)
            return
        }
        let row = view.rowSize(for: page)
        let visible = view.visibleSize
        #expect(row.width <= visible.width + 1 && row.height <= visible.height + 1, sourceLocation: sourceLocation)
        // And it is as large as it can be in one dimension.
        let fills = abs(row.width - visible.width) < 2 || abs(row.height - visible.height) < 2
        #expect(fills, "row \(row) vs visible \(visible)", sourceLocation: sourceLocation)
    }
}

@MainActor
@Suite struct ReaderWindowPasswordTests {
    @Test func lockedDocumentAsksForThePasswordBeforeShowingPages() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: "user", owner: "owner")))
        defer { harness.close() }
        #expect(!harness.controller.isShowingContent)
        #expect(!harness.isEnabled(#selector(ReaderWindowController.increaseZoom(_:))))

        harness.controller.checkPasswordsIfNeeded()
        let prompt = try #require(harness.lastPrompt)
        #expect(prompt.purpose == .open)
        #expect(!prompt.remember)
        #expect(harness.controller.passwordPrompt === prompt)
    }

    @Test func wrongPasswordSaysSoAndKeepsThePromptUp() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: "user", owner: "owner")))
        defer { harness.close() }
        harness.controller.checkPasswordsIfNeeded()
        let prompt = try #require(harness.lastPrompt)

        prompt.password = "nope"
        prompt.submit()
        #expect(prompt.errorMessage == "That password is incorrect. Try again.")
        #expect(prompt.password.isEmpty)
        #expect(harness.document.isPasswordLocked)
        #expect(harness.presenter.dismissals == 0)
        #expect(!harness.controller.isShowingContent)
    }

    @Test func rightPasswordShowsThePagesAndIsNotRememberedByDefault() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: "user", owner: "owner")))
        defer { harness.close() }
        harness.controller.checkPasswordsIfNeeded()
        let prompt = try #require(harness.lastPrompt)

        prompt.password = "user"
        prompt.submit()
        #expect(prompt.errorMessage == nil)
        #expect(harness.presenter.dismissals == 1)
        #expect(harness.controller.passwordPrompt == nil)
        #expect(harness.controller.isShowingContent)
        #expect(harness.pdfView.document === harness.document.pdfDocument)
        #expect(harness.store.all.isEmpty)
    }

    @Test func rememberStoresThePasswordUnderTheDocumentKey() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: "user", owner: "owner")))
        defer { harness.close() }
        harness.controller.checkPasswordsIfNeeded()
        let prompt = try #require(harness.lastPrompt)
        prompt.password = "user"
        prompt.remember = true
        prompt.submit()
        #expect(harness.store.all == [harness.document.documentKey: "user"])
    }

    @Test func rememberedPasswordOpensWithoutAsking() throws {
        let data = try #require(TestPDF.encrypted(user: "user", owner: "owner"))
        let store = InMemoryPasswordStore([DocumentKey(pdfData: data): "user"])
        let harness = try Harness(data, store: store)
        defer { harness.close() }
        harness.controller.checkPasswordsIfNeeded()
        #expect(harness.presenter.prompts.isEmpty)
        #expect(harness.controller.isShowingContent)
    }

    @Test func staleRememberedPasswordIsForgottenAndTheUserIsAsked() throws {
        let data = try #require(TestPDF.encrypted(user: "user", owner: "owner"))
        let store = InMemoryPasswordStore([DocumentKey(pdfData: data): "old"])
        let harness = try Harness(data, store: store)
        defer { harness.close() }
        harness.controller.checkPasswordsIfNeeded()
        #expect(harness.presenter.prompts.count == 1)
        #expect(store.all.isEmpty)
    }

    @Test func cancelClosesTheDocument() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: "user", owner: "owner")))
        harness.controller.checkPasswordsIfNeeded()
        let prompt = try #require(harness.lastPrompt)
        prompt.cancel()
        #expect(harness.presenter.dismissals == 1)
        #expect(harness.document.windowControllers.isEmpty)
        #expect(harness.controller.window?.isVisible != true)
    }

    @Test func realSheetAppearsAndCancelClosesCleanly() throws {
        let document = try ReaderDocument.loaded(try #require(TestPDF.encrypted(user: "user", owner: "owner")))
        let controller = ReaderWindowController(document: document, passwordStore: InMemoryPasswordStore(), presenter: SheetPresenter())
        document.addWindowController(controller)
        controller.showWindow(nil)
        let window = try #require(controller.window)
        #expect(window.attachedSheet != nil)

        controller.passwordPrompt?.cancel()
        #expect(window.attachedSheet == nil)
        #expect(!window.isVisible)
        #expect(document.windowControllers.isEmpty)
    }

    @Test func unencryptedDocumentsNeverConsultTheStore() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 1)))
        defer { harness.close() }
        harness.controller.checkPasswordsIfNeeded()
        #expect(harness.presenter.prompts.isEmpty)
        #expect(harness.document.hasOwnerAccess)
    }
}

@MainActor
@Suite struct ReaderWindowPermissionTests {
    @Test func blockedCopyIsExplainedNotIgnored() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: nil, owner: "owner", allowsPrinting: true)))
        defer { harness.close() }
        #expect(!harness.pdfView.isCopyAllowed)
        let changeCount = NSPasteboard.general.changeCount
        harness.pdfView.copy(nil)
        #expect(harness.presenter.explained == [.copy])
        #expect(NSPasteboard.general.changeCount == changeCount)
    }

    @Test func copyStaysEnabledOnRestrictedDocumentsSoItCanExplain() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: nil, owner: "owner", allowsPrinting: true)))
        defer { harness.close() }
        // With and without a selection: PDFKit may refuse to select restricted text.
        #expect(isCopyEnabled(on: harness.pdfView))
        harness.pdfView.selectAll(nil)
        #expect(isCopyEnabled(on: harness.pdfView))
    }

    @Test func unrestrictedDocumentsAllowCopyingTheSelection() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 1)))
        defer { harness.close() }
        harness.pdfView.selectAll(nil)
        #expect(isCopyEnabled(on: harness.pdfView))
        #expect(harness.pdfView.isCopyAllowed)
    }

    @Test func blockedPrintIsExplainedNotIgnored() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: nil, owner: "owner", allowsCopying: true)))
        defer { harness.close() }
        harness.document.printDocument(nil)
        #expect(harness.presenter.explained == [.print])
    }

    @Test func ownerPasswordFromTheExplanationLiftsTheRestrictions() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: nil, owner: "owner")))
        defer { harness.close() }
        harness.pdfView.copy(nil)
        let enterOwnerPassword = try #require(harness.presenter.enterOwnerPassword)
        enterOwnerPassword()
        let prompt = try #require(harness.lastPrompt)
        #expect(prompt.purpose == .removeRestrictions)

        prompt.password = "wrong"
        prompt.submit()
        #expect(prompt.errorMessage == "That isn’t the owner password. Try again.")

        prompt.password = "owner"
        prompt.submit()
        #expect(prompt.errorMessage == nil)
        #expect(harness.pdfView.isCopyAllowed)
        #expect(harness.document.allowsPrinting)
        #expect(throws: Never.self) { try harness.document.printOperation(withSettings: [:]) }
    }

    @Test func userPasswordIsNotAcceptedAsTheOwnerPassword() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: "user", owner: "owner")))
        defer { harness.close() }
        harness.controller.checkPasswordsIfNeeded()
        harness.lastPrompt?.password = "user"
        harness.lastPrompt?.submit()
        #expect(harness.controller.isShowingContent)

        harness.controller.promptForPassword(.removeRestrictions)
        let prompt = try #require(harness.lastPrompt)
        prompt.password = "user"
        prompt.submit()
        #expect(prompt.errorMessage != nil)
        #expect(!harness.pdfView.isCopyAllowed)
    }

    @Test func cancellingTheOwnerPromptKeepsTheDocumentOpen() throws {
        let harness = try Harness(try #require(TestPDF.encrypted(user: nil, owner: "owner")))
        defer { harness.close() }
        harness.controller.promptForPassword(.removeRestrictions)
        harness.lastPrompt?.cancel()
        #expect(harness.document.windowControllers.count == 1)
        #expect(harness.controller.isShowingContent)
    }

    @Test func rememberedOwnerPasswordLiftsRestrictionsOnOpen() throws {
        let data = try #require(TestPDF.encrypted(user: nil, owner: "owner"))
        let harness = try Harness(data, store: InMemoryPasswordStore([DocumentKey(pdfData: data): "owner"]))
        defer { harness.close() }
        harness.controller.checkPasswordsIfNeeded()
        #expect(harness.presenter.prompts.isEmpty)
        #expect(harness.document.hasOwnerAccess)
        #expect(harness.pdfView.isCopyAllowed)
    }
}

@MainActor
@Suite struct ReaderToolbarTests {
    @Test func everyToolbarItemHasALabelAnImageAndATooltip() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 1)))
        defer { harness.close() }
        let toolbar = try #require(harness.controller.window?.toolbar)
        let identifiers = harness.controller.toolbarDefaultItemIdentifiers(toolbar).filter { $0 != .flexibleSpace }
        #expect(identifiers == [.zoomOut, .zoomIn, .zoomMenu, .readingOptions])
        for identifier in identifiers {
            let item = try #require(harness.controller.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true))
            #expect(!item.label.isEmpty)
            #expect(item.toolTip?.isEmpty == false)
            #expect(item.image?.accessibilityDescription == item.label)
        }
    }

    @Test func readingOptionsMenuOffersEveryLayoutCommand() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 1)))
        defer { harness.close() }
        let toolbar = try #require(harness.controller.window?.toolbar)
        let item = try #require(harness.controller.toolbar(toolbar, itemForItemIdentifier: .readingOptions, willBeInsertedIntoToolbar: true) as? NSMenuToolbarItem)
        let actions = Set(item.menu.items.compactMap(\.action))
        let expected: [Selector] = [
            #selector(ReaderWindowController.showSinglePage(_:)),
            #selector(ReaderWindowController.showTwoPages(_:)),
            #selector(ReaderWindowController.scrollContinuously(_:)),
            #selector(ReaderWindowController.scrollPageByPage(_:)),
            #selector(ReaderWindowController.toggleCoverPage(_:)),
            #selector(ReaderWindowController.toggleRightToLeft(_:)),
            #selector(ReaderWindowController.rotateDocumentLeft(_:)),
            #selector(ReaderWindowController.rotateDocumentRight(_:)),
        ]
        #expect(Set(expected).isSubset(of: actions))
    }

    @Test func zoomButtonsAreValidatedByTheController() throws {
        let harness = try Harness(try #require(TestPDF.make(pageCount: 1)))
        defer { harness.close() }
        let item = NSToolbarItem(itemIdentifier: .zoomIn)
        item.action = #selector(ReaderWindowController.increaseZoom(_:))
        #expect(harness.controller.validateToolbarItem(item))
        harness.pdfView.scaleFactor = ZoomMode.maximumScale
        #expect(!harness.controller.validateToolbarItem(item))
    }
}
