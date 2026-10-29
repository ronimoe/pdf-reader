import AppKit
import PDFKit
import ReaderCore
import ReaderKit
import ReaderUI
import SwiftUI
import Testing
@testable import Lectern

extension M5Tests {
    @MainActor
    @Suite struct AccessibilityTests {
        private func readerWithEverything() throws -> M5Harness {
            let data = FixturePDF.make(
                pageTexts: (1...6).map { "Page \($0) text" },
                outline: [.init(title: "Start", page: 0), .init(title: "Later", page: 3)]
            )
            let h = try M5Harness(data, size: NSSize(width: 1000, height: 760))
            h.read(at: 2)
            h.controller.toggleBookmark(nil)
            h.controller.setSidebarVisible(true)
            return h
        }

        @Test func theAuditCatchesAnUnnamedControlAndOneTheKeyboardCantReach() throws {
            let h = try readerWithEverything()
            defer { h.close() }
            let unnamed = NSButton(image: NSImage(size: NSSize(width: 10, height: 10)), target: nil, action: nil)
            let unreachable = NSButton(title: "Named", target: nil, action: nil)
            unreachable.refusesFirstResponder = true
            h.window.contentView?.addSubview(unnamed)
            h.window.contentView?.addSubview(unreachable)
            let issues = AccessibilityAudit.audit(window: h.window)
            #expect(issues.contains { $0.element.hasPrefix("NSButton") && $0.problem == "has no accessible name" })
            #expect(issues.contains { $0.element.contains("Named") && $0.problem.contains("first responder") })
            unnamed.removeFromSuperview()
            unreachable.removeFromSuperview()
        }

        @Test func theAuditSeesSwiftUIControls() throws {
            let model = SettingsModel()
            let view = NSHostingView(rootView: SettingsView(model: model, tab: .updates))
            _ = AccessibilityAudit.audit(hostedView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            M5Harness.prepareInvisible(window)
            window.contentView = view
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            spin(timeout: 0.2) { false }
            defer { window.orderOut(nil) }
            let elements = AccessibilityAudit.interactiveElements(in: view)
            #expect(elements.contains { $0.contains("Check for updates now") }, "\(elements)")
            #expect(elements.contains { $0.contains("Check for updates automatically") }, "\(elements)")
        }

        @Test func everyReaderControlIsNamedAndReachableInEverySidebarSection() throws {
            let h = try readerWithEverything()
            defer { h.close() }
            for section in [SidebarSection.thumbnails, .outline, .bookmarks, .annotations] {
                h.controller.showSidebarSection(section)
                let issues = AccessibilityAudit.audit(window: h.window)
                #expect(issues.isEmpty, "\(section): \(issues)")
            }
            h.controller.startSearch("text")
            spin(timeout: 2) { h.controller.searchSection.isViewLoaded }
            #expect(AccessibilityAudit.audit(window: h.window).isEmpty, "search: \(AccessibilityAudit.audit(window: h.window))")
            h.controller.endSearch()
        }

        @Test func theSplitAndTheSelectionBarAreNamed() throws {
            let h = try readerWithEverything()
            defer { h.close() }
            h.controller.openSplit()
            let bar = h.view.selectionBar
            bar.isHidden = false
            defer { bar.isHidden = true }
            let issues = AccessibilityAudit.audit(window: h.window)
            #expect(issues.isEmpty, "\(issues)")
            // The bar's actions and colours are named, and every one is in the Annotate menu.
            for (action, button) in bar.actionButtons {
                #expect(button.accessibilityLabel() == action.title)
            }
            let colours = bar.colorButton.menu?.items.dropFirst().map(\.title) ?? []
            #expect(colours == AnnotationColorPreset.allCases.map(\.name))
            let menuTitles = Set(allMenuItems(MainMenu.make()).map(\.title))
            #expect(menuTitles.isSuperset(of: ["Highlight", "Underline", "Strike Through", "Add Comment to Selection…"] + AnnotationColorPreset.allCases.map(\.name)))
        }

        @Test func popoversAreNamed() throws {
            let h = try readerWithEverything()
            defer { h.close() }
            let pdf = try #require(h.view.document)
            let destination = PDFDestination(page: try #require(pdf.page(at: 3)), at: CGPoint(x: 0, y: 700))
            let preview = LinkPreviewController(document: pdf, destination: destination, linkText: "Later", trigger: .keyboard)
            #expect(AccessibilityAudit.audit(hostedView: preview.view, size: preview.view.frame.size).isEmpty)
            let editor = AnnotationTextEditorController(heading: "Note", text: "Hello")
            #expect(AccessibilityAudit.audit(hostedView: editor.view, size: editor.view.frame.size).isEmpty)
        }

        @Test func swiftUIScreensAreNamed() throws {
            let settings = SettingsModel()
            for tab in SettingsView.Tab.allCases {
                let issues = AccessibilityAudit.audit(hostedView: NSHostingView(rootView: SettingsView(model: settings, tab: tab)))
                #expect(issues.isEmpty, "Settings \(tab): \(issues)")
            }
            let empty = EmptyStateModel(recents: [URL(fileURLWithPath: "/tmp/Paper.pdf")])
            #expect(AccessibilityAudit.audit(hostedView: NSHostingView(rootView: EmptyStateView(model: empty))).isEmpty)
            let groups = KeyboardShortcutCatalog.groups(from: MainMenu.make())
            #expect(AccessibilityAudit.audit(hostedView: NSHostingView(rootView: KeyboardShortcutsView(groups: groups))).isEmpty)
            let password = PasswordPromptModel(documentName: "Secret.pdf", purpose: .open)
            #expect(AccessibilityAudit.audit(hostedView: NSHostingView(rootView: PasswordPromptView(model: password))).isEmpty)
            let goTo = GoToPageModel(numbering: PageNumbering(pageCount: 10), currentPageIndex: 0)
            #expect(AccessibilityAudit.audit(hostedView: NSHostingView(rootView: GoToPageView(model: goTo))).isEmpty)
        }

        @Test func everyToolbarButtonHasAMenuEquivalent() throws {
            let h = try readerWithEverything()
            defer { h.close() }
            #expect(AccessibilityAudit.audit(toolbar: h.window.toolbar).isEmpty)
        }

        // MARK: Reduce Motion

        @Test func reduceMotionTurnsOffPopoverAnimation() {
            Motion.reduceMotionOverride = true
            defer { Motion.reduceMotionOverride = nil }
            #expect(!PopoverPreviewPresenter.makePopover(animates: true).animates)
            #expect(!SheetPresenter.makeEditorPopover().animates)
            Motion.reduceMotionOverride = false
            #expect(PopoverPreviewPresenter.makePopover(animates: true).animates)
            #expect(SheetPresenter.makeEditorPopover().animates)
        }

        // MARK: Scanned pages (spec §9.3)

        @Test func aScannedDocumentDoesntClaimToBeReadable() async throws {
            let h = try M5Harness(FixturePDF.make(pageTexts: [nil, nil, nil]))
            defer { h.close() }
            await h.controller.waitForTextInventory()
            let help = h.view.accessibilityHelp() ?? ""
            #expect(help.contains("no text"), "\(help)")
            #expect(h.controller.paneContainers[.primary]?.accessibilityValue() as? String == "No readable text")
        }

        @Test func aPartlyScannedDocumentSaysHowMuch() async throws {
            let h = try M5Harness(FixturePDF.make(pageTexts: ["Words", nil, "More words", nil]))
            defer { h.close() }
            await h.controller.waitForTextInventory()
            #expect(h.view.accessibilityHelp()?.contains("2 of 4 pages") == true, "\(h.view.accessibilityHelp() ?? "")")
        }

        @Test func aDocumentWithTextSaysNothingExtra() async throws {
            let h = try M5Harness(FixturePDF.make(pageTexts: ["Words", "More"]))
            defer { h.close() }
            await h.controller.waitForTextInventory()
            #expect((h.view.accessibilityHelp() ?? "").isEmpty)
        }

        // MARK: Colour

        @Test func theFocusBarFollowsTheAppearance() throws {
            let h = try readerWithEverything()
            defer { h.close() }
            h.controller.openSplit()
            let container = try #require(h.controller.paneContainers[.primary])
            // The helper resolves a dynamic colour in the view's appearance.
            h.window.appearance = NSAppearance(named: .aqua)
            let light = container.resolvedCGColor(.labelColor)
            h.window.appearance = NSAppearance(named: .darkAqua)
            #expect(container.resolvedCGColor(.labelColor) != light)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                h.window.appearance = NSAppearance(named: name)
                // A stale colour is replaced when the appearance changes.
                container.focusBar.layer?.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                container.viewDidChangeEffectiveAppearance()
                var expected: CGColor?
                container.effectiveAppearance.performAsCurrentDrawingAppearance { expected = NSColor.controlAccentColor.cgColor }
                #expect(container.focusBar.layer?.backgroundColor == expected, "\(name.rawValue)")
            }
            h.window.appearance = nil
        }
    }
}
