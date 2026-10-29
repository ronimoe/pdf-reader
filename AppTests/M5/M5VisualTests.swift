import AppKit
import PDFKit
import ReaderCore
import ReaderUI
import Testing
@testable import Lectern

/// M5 review, visual findings V2 and V3 (V1 and V4 are checked by the snapshot tests).
extension M5Tests {
    @MainActor
    @Suite struct M5VisualTests {
        private static let longTitle = "Background and Motivation for Graph-Regularized Energy Functions in Very Long Section Titles"

        @Test func longOutlineTitlesEndInAnEllipsisWithTheFullTitleAsATooltip() throws {
            let data = FixturePDF.make(pageTexts: ["One", "Two"], outline: [.init(title: Self.longTitle, page: 1)])
            let h = try M5Harness(data, size: NSSize(width: 900, height: 600))
            defer { h.close() }
            h.controller.setSidebarVisible(true)
            h.controller.showSidebarSection(.outline)
            h.controller.splitViewController.splitView.setPosition(200, ofDividerAt: 0)
            h.controller.splitViewController.view.layoutSubtreeIfNeeded()
            let outline = h.controller.outlineSection.outlineView
            outline.layoutSubtreeIfNeeded()
            let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
            cell.layoutSubtreeIfNeeded()
            let label = try #require(cell.textField)
            #expect(label.lineBreakMode == .byTruncatingTail)
            #expect(cell.toolTip == Self.longTitle)
            // The label ends inside the visible sidebar, so AppKit draws "…" rather than the
            // scroll view clipping the text mid-word.
            let visible = try #require(outline.enclosingScrollView?.contentView.bounds)
            let labelFrame = outline.convert(label.bounds, from: label)
            #expect(labelFrame.maxX <= visible.maxX + 0.5, "label \\(labelFrame) visible \\(visible)")
            #expect(outline.tableColumns[0].width <= visible.width + 0.5)
        }

        @Test func longBookmarkNamesTruncateWithATooltip() throws {
            let h = try M5Harness(FixturePDF.make(pageTexts: ["One", "Two", "Three"]), size: NSSize(width: 900, height: 600))
            defer { h.close() }
            h.read(at: 1)
            h.controller.toggleBookmark(nil)
            h.presenter.bookmarkName = Self.longTitle
            h.controller.renameBookmarkMenu(nil)
            h.controller.showBookmarkList(nil)
            h.controller.splitViewController.splitView.setPosition(200, ofDividerAt: 0)
            h.controller.splitViewController.view.layoutSubtreeIfNeeded()
            let table = h.controller.bookmarksSection.tableView
            let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
            cell.layoutSubtreeIfNeeded()
            #expect(cell.textField?.lineBreakMode == .byTruncatingTail)
            #expect(cell.toolTip?.hasPrefix(Self.longTitle) == true)
            let visible = try #require(table.enclosingScrollView?.contentView.bounds)
            #expect(table.tableColumns[0].width <= visible.width + 0.5)
        }

        @Test func theNoteEditorIsWideAndScrollsInsteadOfClipping() throws {
            let long = String(repeating: "Check this against the second experiment before citing it. ", count: 12)
            let editor = AnnotationTextEditorController(heading: "Comment", text: long)
            let view = editor.view
            #expect((280...320).contains(editor.preferredContentSize.width), "\\(editor.preferredContentSize)")
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: editor.preferredContentSize), styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let scroll = editor.scrollView
            let textView = editor.textView
            let layout = try #require(textView.layoutManager)
            let container = try #require(textView.textContainer)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            // About five lines show; the rest scrolls, and the text view holds all of it.
            let lineHeight = layout.defaultLineHeight(for: textView.font!)
            #expect(scroll.contentView.bounds.height >= lineHeight * 4.5 && scroll.contentView.bounds.height <= lineHeight * 6.5)
            #expect(textView.frame.width >= scroll.contentView.bounds.width - 1, "wraps at the scroll view's width")
            #expect(used.height + textView.textContainerInset.height <= textView.frame.height + 1, "nothing is cut off at the bottom")
            #expect(textView.frame.height > scroll.contentView.bounds.height, "long text scrolls")
            #expect(used.width <= textView.frame.width, "nothing is cut off at the side")
            window.contentView = nil
        }
    }
}
