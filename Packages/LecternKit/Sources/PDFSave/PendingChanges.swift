import Foundation

/// The ordered list of annotation changes the user made since the file was opened or last saved
/// (A1). The app records every user action here explicitly; nothing is ever worked out by
/// comparing PDFKit's annotation list with the file.
///
/// An annotation added since the last save has no object in the file yet, so the writer can't
/// address it by `ObjectRef`. Changes to such an annotation are folded into its pending add:
/// a colour or comment edit updates the add, and a delete removes it. Changes to annotations that
/// are in the file are appended, except that a colour or comment edit replaces an earlier pending
/// edit of the same kind on the same object, which keeps the journal small.
public struct PendingChanges: Sendable, Equatable, Codable {
    public private(set) var changes: [AnnotationChange]

    public init(_ changes: [AnnotationChange] = []) { self.changes = changes }

    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }

    /// The `/NM` of every annotation added since the last save, in order.
    public var addedNames: [String] { changes.compactMap(\.addedName) }

    /// The pending add for `name`, if there is one.
    public func added(named name: String) -> AnnotationChange? {
        changes.first { $0.addedName == name }
    }

    // MARK: New annotations

    /// Appends a new highlight, underline, strike-out or note. Throws `.duplicateName` if an add
    /// with the same `/NM` is already pending.
    public mutating func add(_ change: AnnotationChange) throws(PDFSaveError) {
        guard let name = change.addedName else { throw .unsupported("not an add: \(change)") }
        guard added(named: name) == nil else { throw .duplicateName(name) }
        changes.append(change)
    }

    /// Removes the pending add for `name` (the user deleted an annotation that was never saved).
    /// Returns the removed change, so an undo can put it back.
    @discardableResult
    public mutating func removeAdd(named name: String) -> AnnotationChange? {
        guard let index = changes.firstIndex(where: { $0.addedName == name }) else { return nil }
        return changes.remove(at: index)
    }

    /// Sets the colour of a pending add. Returns false if there is none for `name`.
    @discardableResult
    public mutating func setColor(_ color: PDFRGBColor, ofAddNamed name: String) -> Bool {
        updateAdd(named: name) { markup in markup.color = color } note: { note in note.color = color }
    }

    /// Sets (or with nil removes) the contents of a pending add.
    @discardableResult
    public mutating func setContents(_ text: String?, ofAddNamed name: String) -> Bool {
        updateAdd(named: name) { markup in markup.contents = text } note: { note in note.contents = text }
    }

    private mutating func updateAdd(named name: String, markup: (inout NewMarkup) -> Void, note: (inout NewNote) -> Void) -> Bool {
        guard let index = changes.firstIndex(where: { $0.addedName == name }) else { return false }
        switch changes[index] {
        case .addMarkup(var m): markup(&m); changes[index] = .addMarkup(m)
        case .addNote(var n): note(&n); changes[index] = .addNote(n)
        default: return false
        }
        return true
    }

    // MARK: Annotations in the file

    /// Records a colour edit of an existing annotation, replacing an earlier pending colour edit
    /// of the same object in place.
    public mutating func editColor(_ ref: ObjectRef, _ color: PDFRGBColor) {
        if let index = changes.firstIndex(where: { if case .editColor(ref, _) = $0 { true } else { false } }) {
            changes[index] = .editColor(ref, color)
        } else {
            changes.append(.editColor(ref, color))
        }
    }

    /// Records a `/Contents` edit of an existing annotation, replacing an earlier pending one.
    public mutating func editContents(_ ref: ObjectRef, _ text: String?) {
        if let index = changes.firstIndex(where: { if case .editContents(ref, _) = $0 { true } else { false } }) {
            changes[index] = .editContents(ref, text)
        } else {
            changes.append(.editContents(ref, text))
        }
    }

    /// Withdraws a pending colour edit (the colour is back to the file's). Returns false if none.
    @discardableResult
    public mutating func cancelColorEdit(of ref: ObjectRef) -> Bool {
        guard let index = changes.firstIndex(where: { if case .editColor(ref, _) = $0 { true } else { false } }) else { return false }
        changes.remove(at: index)
        return true
    }

    /// Withdraws a pending `/Contents` edit (the text is back to the file's). Returns false if none.
    @discardableResult
    public mutating func cancelContentsEdit(of ref: ObjectRef) -> Bool {
        guard let index = changes.firstIndex(where: { if case .editContents(ref, _) = $0 { true } else { false } }) else { return false }
        changes.remove(at: index)
        return true
    }

    /// The pending colour of an existing annotation, if it was changed since the last save.
    public func pendingColor(of ref: ObjectRef) -> PDFRGBColor? {
        for change in changes { if case .editColor(ref, let color) = change { return color } }
        return nil
    }

    /// Records the deletion of an existing annotation.
    public mutating func delete(_ ref: ObjectRef) {
        guard !hasPendingDelete(of: ref) else { return }
        changes.append(.delete(ref))
    }

    public func hasPendingDelete(of ref: ObjectRef) -> Bool {
        changes.contains(.delete(ref))
    }

    /// Withdraws a pending delete (the user undid it before saving). Returns false if there was none.
    @discardableResult
    public mutating func cancelDelete(of ref: ObjectRef) -> Bool {
        guard let index = changes.firstIndex(of: .delete(ref)) else { return false }
        changes.remove(at: index)
        return true
    }

    /// Everything was saved.
    public mutating func removeAll() { changes.removeAll() }

    /// What the list amounts to, for the writer: each annotation's net change. The list itself
    /// (and so undo) is left as it is.
    /// - An edit followed by a delete of the same file annotation is just the delete. (Undoing a
    ///   comment on a saved highlight, then the highlight itself, records exactly that.)
    /// - Adds already carry their final state, and an add that was deleted again before a save
    ///   has already left the list (`setContents(_:ofAddNamed:)`, `removeAdd(named:)`); a delete of an annotation that was
    ///   in the file stays a delete.
    public var netChanges: [AnnotationChange] {
        let deleted = Set(changes.compactMap { change -> ObjectRef? in if case .delete(let ref) = change { ref } else { nil } })
        guard !deleted.isEmpty else { return changes }
        return changes.filter { change in
            switch change {
            case .editColor(let ref, _), .editContents(let ref, _): !deleted.contains(ref)
            default: true
            }
        }
    }
}

extension AnnotationChange {
    /// The `/NM` of an added annotation; nil for edits and deletes.
    public var addedName: String? {
        switch self {
        case .addMarkup(let m): m.name
        case .addNote(let n): n.name
        default: nil
        }
    }

    /// The existing object an edit or delete addresses; nil for adds.
    public var target: ObjectRef? {
        switch self {
        case .editContents(let r, _), .editColor(let r, _), .delete(let r): r
        default: nil
        }
    }
}
