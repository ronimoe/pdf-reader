import AppKit
import PDFKit
import PDFSave
import Persistence
import ReaderCore
import ReaderKit

/// Why an annotation action did nothing (B6, A1). Every refusal is explained to the user; none
/// is silent (Rule 7).
enum AnnotationRefusal: Error, Equatable {
    /// The document's permissions don't allow commenting (B6). The owner password lifts it.
    case commentingNotAllowed
    /// Saveability is still being worked out in the background.
    case stillChecking
    /// The document can't be saved with annotations at all.
    case cannotSave(UnsupportedReason)
    /// The annotation couldn't be matched to exactly one object in the file.
    case notMatched(AnnotationMatch)
    /// The annotation isn't one Lectern can change this way.
    case notEditable(kind: String)
    /// Its colour can't be changed (the writer only redraws markup and notes).
    case colorNotChangeable(kind: String)
    /// A saved deletion of this kind of annotation can't be put back.
    case cannotRestore(kind: String)
    /// The selection has no text that markup can cover.
    case nothingToMark
    /// Journaled changes no longer match what is on the pages.
    case journalDoesNotApply

    var title: String {
        switch self {
        case .commentingNotAllowed: "This document doesn’t allow annotations"
        case .stillChecking: "Lectern is still checking this document"
        case .cannotSave: "Annotations can’t be saved in this document"
        case .notMatched: "This annotation can’t be changed safely"
        case .notEditable: "This annotation can’t be changed"
        case .colorNotChangeable: "This annotation’s colour can’t be changed"
        case .cannotRestore: "This annotation can’t be put back"
        case .nothingToMark: "There’s no text to mark"
        case .journalDoesNotApply: "The unsaved annotations can’t be restored"
        }
    }

    var message: String {
        switch self {
        case .commentingNotAllowed:
            "Its author restricted adding and changing annotations. If you have the owner password, you can enter it to remove the restriction."
        case .stillChecking:
            "It takes a moment to check whether a document can be saved with annotations. Try again in a second."
        case .cannotSave(.encrypted):
            "This document is encrypted, and this version of Lectern can’t save annotations into encrypted documents. You can still read it, and nothing in the file is changed."
        case .cannotSave(.malformed), .cannotSave(.unsupportedStructure):
            "Lectern couldn’t read this file’s structure reliably enough to add to it without risking damage, so it won’t change it. You can still read it."
        case .notMatched(.ambiguous):
            "Several annotations in the file fit its position and text equally well, so Lectern can’t tell which one to change. It leaves the file as it is rather than guess."
        case .notMatched(.unaddressable):
            "It is written inside the page in a way that can’t be changed on its own. Lectern leaves it as it is."
        case .notMatched:
            "Lectern couldn’t find this annotation in the file, so it can’t change it safely."
        case .notEditable(let kind):
            "\(kind) annotations are part of another feature and can’t be edited here."
        case .colorNotChangeable(let kind):
            "Lectern can change the colour of highlights, underlines, strike-throughs and notes. This one is a \(kind.lowercased())."
        case .cannotRestore(let kind):
            "Its deletion was already saved, and Lectern can recreate only highlights, underlines, strike-throughs and notes. This one is a \(kind.lowercased())."
        case .nothingToMark:
            "Select some text on the page first."
        case .journalDoesNotApply:
            "They were recorded for this file, but some of the annotations they change can’t be found on its pages. They are kept, so nothing is lost."
        }
    }

    /// Offers the owner password, as for other permission restrictions (B6).
    var offersOwnerPassword: Bool { self == .commentingNotAllowed }
}

/// What a background look at the file found (architecture §3.2, §4.6).
struct AnnotationFileInfo: Sendable {
    var saveability: Saveability
    var descriptors: [AnnotationDescriptor]
    var sha256: String

    /// Parses the file off the main thread: Saveability, every annotation's descriptor, and the
    /// SHA-256 the crash journal is keyed to.
    nonisolated static func inspect(_ data: Data, readOnlyLocation: Bool) async -> AnnotationFileInfo {
        await Task.detached(priority: .userInitiated) {
            let saveability = Saveability.evaluate(data, readOnlyLocation: readOnlyLocation)
            var descriptors: [AnnotationDescriptor] = []
            if case .unsupported = saveability {} else {
                descriptors = (try? PDFSaveDocument(data: data).annotations()) ?? []
            }
            return AnnotationFileInfo(saveability: saveability, descriptors: descriptors, sha256: JournalHash.of(data))
        }.value
    }
}

enum JournalHash {
    nonisolated static func of(_ data: Data) -> String {
        JournalEntry.hash(of: data)
    }
}

/// The document's annotations, as the user changes them (B4, A1).
///
/// **Every user action is tracked explicitly.** Each action updates the ordered `PendingChanges`
/// list the writer will save, and makes the same change to the PDFKit model for display. Nothing
/// is ever worked out by comparing PDFKit's annotations with the file: PDFKit can hold
/// annotations the user never made (popups, for one).
///
/// **Addressing annotations in the file.** Before anything on a page changes, all of that page's
/// PDFKit annotations are matched to file objects in one `AnnotationMatcher` batch, using what
/// PDFKit reports at that moment, which is still the state at open (or at the last save): every
/// change goes through here, after the page is matched. Anything but a unique match is refused
/// with an explanation.
///
/// **Undo** registers the inverse *action* on the annotation object, not a snapshot of the list,
/// so it works across a save: undoing an add that was saved deletes it from the file (a new
/// unsaved change), and undoing a saved deletion recreates the annotation.
@MainActor
final class AnnotationEditor {
    let pdf: PDFDocument
    private(set) var original: Data
    private(set) var info: AnnotationFileInfo?
    private(set) var pending = PendingChanges()
    weak var undoManager: UndoManager?
    /// The author written into new annotations' `/T` (B4). Empty or nil writes none.
    var author: () -> String? = { nil }
    /// Called after every change to the pending list or the displayed annotations.
    var onChange: (() -> Void)?

    /// Annotations added since the last save, by object, with their `/NM`.
    private var newNames: [ObjectIdentifier: String] = [:]
    /// What each matched PDFKit annotation is in the file.
    private var matches: [ObjectIdentifier: AnnotationMatch] = [:]
    private var matchedPages: Set<Int> = []
    /// Strong references, so an `ObjectIdentifier` can't be reused while it means something here.
    private var known: [ObjectIdentifier: PDFAnnotation] = [:]
    /// The add a deleted, never-saved annotation had, for undo.
    private var removedAdds: [ObjectIdentifier: AnnotationChange] = [:]
    /// The object a deleted file annotation was, for undo.
    private var deletedRefs: [ObjectIdentifier: ObjectRef] = [:]

    init(pdf: PDFDocument, original: Data) {
        self.pdf = pdf
        self.original = original
    }

    var hasUnsavedChanges: Bool { !pending.isEmpty }
    var saveability: Saveability? { info?.saveability }
    var originalSHA256: String? { info?.sha256 }

    func load(_ info: AnnotationFileInfo) {
        self.info = info
        matches = [:]
        matchedPages = []
    }

    // MARK: Permission

    /// Nil when annotations can be created and changed; otherwise why not.
    var refusal: AnnotationRefusal? {
        if pdf.isLocked || !pdf.allowsCommenting { return .commentingNotAllowed }
        guard let saveability = info?.saveability else { return .stillChecking }
        if case .unsupported(let reason) = saveability { return .cannotSave(reason) }
        return nil
    }

    // MARK: Creating

    /// Marks up `selection`: one annotation per page it covers, as one undoable action.
    @discardableResult
    func addMarkup(_ kind: MarkupKind, covering selection: PDFSelection, color: AnnotationColorPreset, contents: String? = nil) throws(AnnotationRefusal) -> [PDFAnnotation] {
        if let refusal { throw refusal }
        var quadsByPage: [(page: PDFPage, index: Int, quads: [Quad])] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let rect = line.bounds(for: page)
                guard rect.width >= 0.5, rect.height >= 0.5 else { continue }
                let index = pdf.index(for: page)
                guard index != NSNotFound else { continue }
                let quad = Quad(rect: PDFRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
                if let at = quadsByPage.firstIndex(where: { $0.index == index }) {
                    quadsByPage[at].quads.append(quad)
                } else {
                    quadsByPage.append((page, index, [quad]))
                }
            }
        }
        guard !quadsByPage.isEmpty else { throw .nothingToMark }
        var created: [PDFAnnotation] = []
        grouped(kind.actionName) {
            for entry in quadsByPage {
                let markup = NewMarkup(kind: kind, pageIndex: entry.index, quads: entry.quads, color: color.pdfColor,
                                       contents: contents, author: currentAuthor)
                let annotation = Self.makeAnnotation(for: .addMarkup(markup))
                created.append(annotation)
                insertNew(annotation, change: .addMarkup(markup), on: entry.page)
            }
        }
        return created
    }

    /// Adds a sticky note whose icon's top-left corner is at `point` on `page`.
    @discardableResult
    func addNote(on page: PDFPage, at point: CGPoint, color: AnnotationColorPreset, text: String? = nil) throws(AnnotationRefusal) -> PDFAnnotation {
        if let refusal { throw refusal }
        let index = pdf.index(for: page)
        let box = page.bounds(for: .mediaBox)
        let x = min(max(point.x, box.minX), box.maxX - 20)
        let y = min(max(point.y - 20, box.minY), box.maxY - 20)
        let note = NewNote(pageIndex: index, origin: PDFPoint(x: x, y: y), color: color.pdfColor, contents: text, author: currentAuthor)
        let annotation = Self.makeAnnotation(for: .addNote(note))
        grouped("Add Note") { insertNew(annotation, change: .addNote(note), on: page) }
        return annotation
    }

    private var currentAuthor: String? {
        guard let author = author()?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty else { return nil }
        return author
    }

    // MARK: Changing

    func setColor(_ color: PDFRGBColor, of annotation: PDFAnnotation) throws(AnnotationRefusal) {
        if let refusal { throw refusal }
        let kind = annotation.type ?? ""
        guard AnnotationKindName.allowsColorChange(subtype: kind) else { throw .colorNotChangeable(kind: AnnotationKindName.name(forSubtype: kind)) }
        let id = ObjectIdentifier(annotation)
        let previous = annotation.color
        let old: PDFRGBColor
        /// Set when the file's own colour was showing: undo then withdraws the edit.
        var revertsToFile: (ref: ObjectRef, hash: String?)?
        if let name = newNames[id] {
            old = pending.added(named: name).flatMap(\.addedColor) ?? Self.rgb(of: annotation)
            pending.setColor(color, ofAddNamed: name)
        } else {
            let ref = try fileRef(of: annotation)
            let fileColor = fileDescriptor(ref)?.color?.rgb
            if pending.pendingColor(of: ref) == nil { revertsToFile = (ref, info?.sha256) }
            old = pending.pendingColor(of: ref) ?? fileColor ?? Self.rgb(of: annotation)
            if let fileColor, fileColor.isClose(to: color) {
                // Back to what the file says: nothing left to save for this colour.
                pending.cancelColorEdit(of: ref)
            } else {
                pending.editColor(ref, color)
            }
        }
        annotation.color = color.nsColor
        if let revertsToFile {
            registerUndo("Change Colour") { (editor: AnnotationEditor) throws(AnnotationRefusal) in
                try editor.revertColor(of: annotation, ref: revertsToFile.ref, to: previous, fileHash: revertsToFile.hash, otherwise: old, redo: color)
            }
        } else {
            registerUndo("Change Colour") { (editor: AnnotationEditor) throws(AnnotationRefusal) in try editor.setColor(old, of: annotation) }
        }
        didChange()
    }

    /// Undo of a recolour made over the file's own colour: the edit is withdrawn and the colour
    /// PDFKit showed comes back, so a file without `/C` never gets one. After a save in between,
    /// the file has the new colour, and undo is a new edit back to the old one.
    private func revertColor(of annotation: PDFAnnotation, ref: ObjectRef, to shown: NSColor, fileHash: String?,
                             otherwise old: PDFRGBColor, redo color: PDFRGBColor) throws(AnnotationRefusal) {
        if let refusal { throw refusal }
        guard info?.sha256 == fileHash, newNames[ObjectIdentifier(annotation)] == nil else {
            try setColor(old, of: annotation)
            return
        }
        pending.cancelColorEdit(of: ref)
        annotation.color = shown
        registerUndo("Change Colour") { (editor: AnnotationEditor) throws(AnnotationRefusal) in try editor.setColor(color, of: annotation) }
        didChange()
    }

    private func fileDescriptor(_ ref: ObjectRef) -> AnnotationDescriptor? {
        info?.descriptors.first { $0.ref == ref }
    }

    /// Sets a note's text or a markup comment; empty text removes it.
    func setContents(_ text: String?, of annotation: PDFAnnotation) throws(AnnotationRefusal) {
        if let refusal { throw refusal }
        let kind = annotation.type ?? ""
        guard AnnotationKindName.isListed(subtype: kind) else { throw .notEditable(kind: AnnotationKindName.name(forSubtype: kind)) }
        let text = text.flatMap { $0.isEmpty ? nil : $0 }
        let old = annotation.contents.flatMap { $0.isEmpty ? nil : $0 }
        guard text != old else { return }
        let id = ObjectIdentifier(annotation)
        if let name = newNames[id] {
            pending.setContents(text, ofAddNamed: name)
        } else {
            let ref = try fileRef(of: annotation)
            if let file = fileDescriptor(ref), (file.contents ?? "") == (text ?? "") {
                pending.cancelContentsEdit(of: ref)
            } else {
                pending.editContents(ref, text)
            }
        }
        annotation.contents = text
        registerUndo(kind == "Text" ? "Edit Note" : "Edit Comment") { (editor: AnnotationEditor) throws(AnnotationRefusal) in try editor.setContents(old, of: annotation) }
        didChange()
    }

    /// Deletes an annotation, with the replies and popup the writer deletes along with it.
    func delete(_ annotation: PDFAnnotation) throws(AnnotationRefusal) {
        if let refusal { throw refusal }
        let kind = annotation.type ?? ""
        guard AnnotationKindName.isListed(subtype: kind) else { throw .notEditable(kind: AnnotationKindName.name(forSubtype: kind)) }
        guard let page = annotation.page else { return }
        let id = ObjectIdentifier(annotation)
        var children: [PDFAnnotation] = []
        if let name = newNames[id] {
            if let change = pending.removeAdd(named: name) { removedAdds[id] = change }
            newNames[id] = nil
            if let popup = annotation.popup, popup.page === page { children.append(popup) }
        } else {
            let ref = try fileRef(of: annotation)
            children = try cascade(of: ref, on: page)
            if let popup = annotation.popup, popup.page === page, !children.contains(where: { $0 === popup }) { children.append(popup) }
            pending.delete(ref)
            deletedRefs[id] = ref
        }
        let pageIndex = pdf.index(for: page)
        for child in children { page.removeAnnotation(child) }
        page.removeAnnotation(annotation)
        registerUndo("Delete Annotation") { (editor: AnnotationEditor) throws(AnnotationRefusal) in try editor.restore(annotation, children: children, onPageAt: pageIndex) }
        didChange()
    }

    /// Puts a deleted annotation back: withdraws a pending delete, re-adds a never-saved
    /// annotation, or (when the deletion was saved) adds it again as a new annotation.
    private func restore(_ annotation: PDFAnnotation, children: [PDFAnnotation], onPageAt pageIndex: Int) throws(AnnotationRefusal) {
        if let refusal { throw refusal }
        guard let page = pdf.page(at: pageIndex) else { return }
        let id = ObjectIdentifier(annotation)
        var restoredChildren = children
        if let change = removedAdds.removeValue(forKey: id), let name = change.addedName {
            try? pending.add(change)
            newNames[id] = name
        } else if let ref = deletedRefs[id], pending.cancelDelete(of: ref) {
            deletedRefs[id] = nil
        } else {
            // The deletion was saved: the object is gone from the page. Recreate it.
            guard let change = Self.recreation(of: annotation, pageIndex: pageIndex, author: currentAuthor) else {
                throw .cannotRestore(kind: AnnotationKindName.name(forSubtype: annotation.type ?? ""))
            }
            try? pending.add(change)
            newNames[id] = change.addedName
            annotation.setValue(change.addedName ?? "", forAnnotationKey: .name)
            deletedRefs[id] = nil
            // Replies and popups aren't recreated: their objects are gone with the saved delete.
            restoredChildren = annotation.popup.map { [$0] } ?? []
        }
        known[id] = annotation
        page.addAnnotation(annotation)
        for child in restoredChildren where child.page == nil { page.addAnnotation(child) }
        registerUndo("Delete Annotation") { (editor: AnnotationEditor) throws(AnnotationRefusal) in try editor.delete(annotation) }
        didChange()
    }

    private func insertNew(_ annotation: PDFAnnotation, change: AnnotationChange, on page: PDFPage) {
        ensureMatched(pageAt: pdf.index(for: page))
        let id = ObjectIdentifier(annotation)
        try? pending.add(change)
        newNames[id] = change.addedName
        known[id] = annotation
        page.addAnnotation(annotation)
        Self.clearAutomaticMetadata(of: annotation, author: change.author)
        registerUndo(change.actionName) { (editor: AnnotationEditor) throws(AnnotationRefusal) in try editor.delete(annotation) }
        didChange()
    }

    // MARK: Journal

    /// Replays journaled changes onto the pages (crash recovery, A1). Every edit and delete must
    /// find its annotation, or nothing is applied.
    func replay(_ changes: [AnnotationChange]) throws(AnnotationRefusal) {
        if let refusal { throw refusal }
        var targets: [ObjectRef: PDFAnnotation] = [:]
        for ref in Set(changes.compactMap(\.target)) {
            guard let annotation = annotation(for: ref) else { throw .journalDoesNotApply }
            targets[ref] = annotation
        }
        for change in changes {
            guard change.addedName == nil || pdf.page(at: change.pageIndex ?? -1) != nil else { throw .journalDoesNotApply }
        }
        for change in changes {
            switch change {
            case .addMarkup, .addNote:
                guard let index = change.pageIndex, let page = pdf.page(at: index) else { continue }
                let annotation = Self.makeAnnotation(for: change)
                ensureMatched(pageAt: index)
                let id = ObjectIdentifier(annotation)
                try? pending.add(change)
                newNames[id] = change.addedName
                known[id] = annotation
                page.addAnnotation(annotation)
                Self.clearAutomaticMetadata(of: annotation, author: change.author)
            case .editColor(let ref, let color):
                targets[ref]?.color = color.nsColor
                pending.editColor(ref, color)
            case .editContents(let ref, let text):
                targets[ref]?.contents = text
                pending.editContents(ref, text)
            case .delete(let ref):
                guard let annotation = targets[ref], let page = annotation.page else { continue }
                for child in (try? cascade(of: ref, on: page)) ?? [] { page.removeAnnotation(child) }
                page.removeAnnotation(annotation)
                deletedRefs[ObjectIdentifier(annotation)] = ref
                pending.delete(ref)
            }
        }
        didChange()
    }

    /// The PDFKit annotation matched to `ref`, if exactly one is.
    func annotation(for ref: ObjectRef) -> PDFAnnotation? {
        guard let descriptor = info?.descriptors.first(where: { $0.ref == ref }) else { return nil }
        ensureMatched(pageAt: descriptor.pageIndex)
        let found = matches.filter { $0.value.ref == ref }.compactMap { known[$0.key] }.filter { $0.page != nil }
        return found.count == 1 ? found[0] : nil
    }

    // MARK: Saving

    /// The save wrote `result`: these bytes are now the original, the list is empty, and matching
    /// starts again from the new file. The pages aren't reloaded.
    func didSave(_ data: Data, descriptors: [AnnotationDescriptor], saveability: Saveability) {
        original = data
        pending.removeAll()
        newNames = [:]
        info = AnnotationFileInfo(saveability: saveability, descriptors: descriptors, sha256: JournalHash.of(data))
        matches = [:]
        matchedPages = []
        didChange()
    }

    func updateSaveability(_ saveability: Saveability) {
        info?.saveability = saveability
    }

    // MARK: Matching

    /// What the file says this annotation is, or why it can't be addressed.
    func match(of annotation: PDFAnnotation) -> AnnotationMatch? {
        if newNames[ObjectIdentifier(annotation)] != nil { return nil }
        guard let page = annotation.page else { return matches[ObjectIdentifier(annotation)] }
        ensureMatched(pageAt: pdf.index(for: page))
        return matches[ObjectIdentifier(annotation)]
    }

    /// True for an annotation added since the last save.
    func isUnsaved(_ annotation: PDFAnnotation) -> Bool { newNames[ObjectIdentifier(annotation)] != nil }

    private func fileRef(of annotation: PDFAnnotation) throws(AnnotationRefusal) -> ObjectRef {
        switch match(of: annotation) {
        case .matched(let ref, _)?: return ref
        case let other?: throw .notMatched(other)
        case nil: throw .notMatched(.notFound)
        }
    }

    /// Matches every annotation PDFKit shows on the page, in one batch, the first time anything on
    /// the page is about to change. Annotations added here since the last save are left out:
    /// they aren't in the file yet.
    private func ensureMatched(pageAt index: Int) {
        guard index != NSNotFound, !matchedPages.contains(index), let info, let page = pdf.page(at: index) else { return }
        matchedPages.insert(index)
        let annotations = page.annotations.filter { newNames[ObjectIdentifier($0)] == nil }
        let queries = annotations.map { annotation in
            let b = annotation.bounds
            return AnnotationQuery(
                pageIndex: index, subtype: annotation.type ?? "",
                rect: PDFRect(x: b.minX, y: b.minY, width: b.width, height: b.height),
                contentsAtOpen: annotation.contents,
                name: annotation.value(forAnnotationKey: .name) as? String
            )
        }
        let results = AnnotationMatcher().match(queries, in: info.descriptors)
        for (annotation, result) in zip(annotations, results) {
            let id = ObjectIdentifier(annotation)
            matches[id] = result
            known[id] = annotation
        }
    }

    /// The annotations the writer deletes along with `ref`: replies (`/IRT`, transitively) and
    /// real popups. Replies must be found on the page, or the delete is refused.
    private func cascade(of ref: ObjectRef, on page: PDFPage) throws(AnnotationRefusal) -> [PDFAnnotation] {
        guard let info else { return [] }
        let index = pdf.index(for: page)
        let onPage = info.descriptors.filter { $0.pageIndex == index }
        var targets: Set<ObjectRef> = [ref]
        var queue = [ref]
        while let current = queue.popLast() {
            for d in onPage where d.inReplyTo == current {
                if let r = d.ref, targets.insert(r).inserted { queue.append(r) }
            }
        }
        var popups: Set<ObjectRef> = []
        for d in onPage {
            guard let owner = d.ref, targets.contains(owner), let popup = d.popup,
                  let p = onPage.first(where: { $0.ref == popup }), p.subtype == "Popup" else { continue }
            popups.insert(popup)
        }
        ensureMatched(pageAt: index)
        var children: [PDFAnnotation] = []
        for target in targets.union(popups) where target != ref {
            let found = page.annotations.filter { matches[ObjectIdentifier($0)]?.ref == target }
            if found.count == 1 {
                children.append(found[0])
            } else if !popups.contains(target) {
                // A reply the reader can see but Lectern can't find: deleting would leave it on
                // screen while the file loses it.
                throw .notMatched(.ambiguous([target]))
            }
        }
        return children
    }

    // MARK: Undo

    private func grouped(_ name: String, _ body: () -> Void) {
        undoManager?.beginUndoGrouping()
        body()
        undoManager?.setActionName(name)
        undoManager?.endUndoGrouping()
    }

    /// Registers `inverse` to run on undo (and, through its own registration, redo). A refused
    /// undo is reported through `onRefusal`.
    private func registerUndo(_ name: String, _ inverse: @escaping (AnnotationEditor) throws(AnnotationRefusal) -> Void) {
        guard let undoManager else { return }
        // Each action is one undo step: inside an event's group, inside `grouped`, or on its own.
        let needsGroup = undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        defer { if needsGroup { undoManager.endUndoGrouping() } }
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                do throws(AnnotationRefusal) {
                    try inverse(editor)
                } catch {
                    editor.onRefusal?(error)
                }
            }
        }
        if !undoManager.isUndoing, !undoManager.isRedoing { undoManager.setActionName(name) }
    }

    /// Called when an undo or redo had to be refused.
    var onRefusal: ((AnnotationRefusal) -> Void)?

    private func didChange() {
        onChange?()
    }

    // MARK: Building PDFKit annotations

    /// The PDFKit annotation that shows a new markup or note, named with its `/NM` and without
    /// the author and date PDFKit fills in on its own (M0b Q5).
    static func makeAnnotation(for change: AnnotationChange) -> PDFAnnotation {
        let annotation: PDFAnnotation
        switch change {
        case .addMarkup(let m):
            let rects = m.quads.map(\.bounds)
            let union = rects.dropFirst().reduce(rects[0]) { a, r in
                PDFRect(corners: min(a.x, r.x), min(a.y, r.y), max(a.maxX, r.maxX), max(a.maxY, r.maxY))
            }
            let bounds = CGRect(x: union.x, y: union.y, width: union.width, height: union.height)
            annotation = PDFAnnotation(bounds: bounds, forType: m.kind.pdfKitSubtype, withProperties: nil)
            // PDFKit's quadrilateral points are relative to the bounds' origin, in Acrobat's order.
            annotation.quadrilateralPoints = m.quads.flatMap { q in
                [q.upperLeft, q.upperRight, q.lowerLeft, q.lowerRight].map {
                    NSValue(point: CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY))
                }
            }
            annotation.color = m.color.nsColor
            annotation.contents = m.contents
        case .addNote(let n):
            annotation = PDFAnnotation(bounds: CGRect(x: n.origin.x, y: n.origin.y, width: 20, height: 20), forType: .text, withProperties: nil)
            annotation.iconType = .comment
            annotation.color = n.color.nsColor
            annotation.contents = n.contents
        default:
            preconditionFailure("not an add")
        }
        annotation.setValue(change.addedName ?? "", forAnnotationKey: .name)
        clearAutomaticMetadata(of: annotation, author: change.author)
        return annotation
    }

    /// PDFKit sets `/T` to the Mac account's full name and `/M` to now on every new annotation
    /// and its popup (M0b Q5). `/T` comes only from Settings (B4).
    static func clearAutomaticMetadata(of annotation: PDFAnnotation, author: String?) {
        annotation.userName = author
        annotation.modificationDate = nil
        if let popup = annotation.popup {
            popup.userName = author
            popup.modificationDate = nil
        }
    }

    /// A new add that recreates `annotation` as it shows now; nil for kinds the writer can't add.
    static func recreation(of annotation: PDFAnnotation, pageIndex: Int, author: String?) -> AnnotationChange? {
        let color = rgb(of: annotation)
        let contents = annotation.contents.flatMap { $0.isEmpty ? nil : $0 }
        switch annotation.type ?? "" {
        case "Highlight", "Underline", "StrikeOut":
            let kind = MarkupKind(rawValue: annotation.type!)!
            let rects = ReaderPDFView.hitRects(of: annotation)
            let quads = rects.map { Quad(rect: PDFRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)) }
            guard !quads.isEmpty else { return nil }
            return .addMarkup(NewMarkup(kind: kind, pageIndex: pageIndex, quads: quads, color: color, contents: contents, author: author))
        case "Text":
            // PDFKit shows notes 24×24 from the top-left corner of their /Rect.
            let b = annotation.bounds
            return .addNote(NewNote(pageIndex: pageIndex, origin: PDFPoint(x: b.minX, y: b.maxY - 20), color: color, contents: contents, author: author))
        default:
            return nil
        }
    }

    static func rgb(of annotation: PDFAnnotation) -> PDFRGBColor {
        guard let c = annotation.color.usingColorSpace(.sRGB) else { return .yellow }
        return PDFRGBColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }
}

extension AnnotationColorPreset {
    var pdfColor: PDFRGBColor {
        let c = rgb
        return PDFRGBColor(red: c.red, green: c.green, blue: c.blue)
    }
}

extension PDFRGBColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    func isClose(to other: PDFRGBColor, tolerance: Double = 0.0005) -> Bool {
        abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance && abs(blue - other.blue) <= tolerance
    }
}

extension MarkupKind {
    var pdfKitSubtype: PDFAnnotationSubtype {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        }
    }

    var actionName: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strike Through"
        }
    }
}

extension AnnotationChange {
    var pageIndex: Int? {
        switch self {
        case .addMarkup(let m): m.pageIndex
        case .addNote(let n): n.pageIndex
        default: nil
        }
    }

    var author: String? {
        switch self {
        case .addMarkup(let m): m.author
        case .addNote(let n): n.author
        default: nil
        }
    }

    var addedColor: PDFRGBColor? {
        switch self {
        case .addMarkup(let m): m.color
        case .addNote(let n): n.color
        default: nil
        }
    }

    var actionName: String {
        switch self {
        case .addMarkup(let m): m.kind.actionName
        case .addNote: "Add Note"
        default: "Change Annotation"
        }
    }
}
