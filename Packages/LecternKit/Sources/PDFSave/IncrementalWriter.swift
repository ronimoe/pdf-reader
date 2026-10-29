import Foundation

/// Appends annotation changes to a PDF as an incremental update (architecture §3.2, candidate 1).
///
/// The output is always `original + update`: the original bytes are never modified. Only the
/// objects that must change are written: new annotations and their appearance streams, edited
/// annotations, and for each touched page either its indirect `/Annots` array or, when the
/// array is direct or absent, the page object itself.
public struct IncrementalWriter: Sendable {
    public struct Options: Sendable {
        /// Write a simple `/AP /N` appearance stream for new annotations.
        public var appearanceStreams: Bool
        /// Used for `/M` and `/CreationDate`.
        public var date: Date
        /// Re-parse the output and check every written object before returning it.
        public var verify: Bool

        public init(appearanceStreams: Bool = true, date: Date = Date(), verify: Bool = true) {
            self.appearanceStreams = appearanceStreams
            self.date = date
            self.verify = verify
        }

        /// Test-only fault injection, so tests can prove the post-write check catches damage.
        var testHooks = TestHooks()
    }

    struct TestHooks: Sendable {
        /// Runs on the objects to write after the expected state is fixed, before serialising.
        var mutateWritten: (@Sendable (inout [ObjectRef: PDFObject]) -> Void)?
        /// Runs on the complete output before verification.
        var mutateOutput: (@Sendable (inout [UInt8]) -> Void)?
    }

    public var options: Options

    public init(options: Options = Options()) { self.options = options }

    public func save(original: Data, changes: [AnnotationChange]) throws(PDFSaveError) -> SaveResult {
        let bytes = [UInt8](original)
        let doc = try PDFSaveDocument(bytes: bytes)
        var session = Session(doc: doc, options: options)
        for change in changes { try session.apply(change) }
        try session.finishPages()
        return try session.serialize(original: bytes)
    }
}

private struct Session {
    let doc: PDFSaveDocument
    let options: IncrementalWriter.Options
    let dateString: String
    var nextNumber: Int
    var written: [ObjectRef: PDFObject] = [:]
    var added: [ObjectRef] = []
    var rewritten = Set<ObjectRef>()
    var removed: [ObjectRef] = []
    /// Working copies of `/Annots` for pages we touched.
    var pageAnnots: [Int: [PDFObject]] = [:]
    var annotationPage: [ObjectRef: Int]?
    var edited = Set<ObjectRef>()

    init(doc: PDFSaveDocument, options: IncrementalWriter.Options) {
        self.doc = doc
        self.options = options
        self.nextNumber = doc.size
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: options.date)
        dateString = String(format: "D:%04d%02d%02d%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    mutating func allocate() throws(PDFSaveError) -> ObjectRef {
        guard nextNumber < PDFSaveDocument.maxObjects else { throw .unsupported("object numbers exhausted") }
        defer { nextNumber += 1 }
        return ObjectRef(nextNumber, 0)
    }

    mutating func annots(_ page: Int) throws(PDFSaveError) -> [PDFObject] {
        if let a = pageAnnots[page] { return a }
        let a = try doc.annots(ofPage: page).items
        pageAnnots[page] = a
        return a
    }

    mutating func page(of ref: ObjectRef) throws(PDFSaveError) -> Int {
        if annotationPage == nil {
            var index: [ObjectRef: Int] = [:]
            for page in 0..<doc.pageCount {
                for item in try doc.annots(ofPage: page).items {
                    if let r = item.referenceValue, index[r] == nil { index[r] = page }
                }
            }
            annotationPage = index
        }
        guard let page = annotationPage?[ref] else { throw .annotationNotFound(ref) }
        return page
    }

    func common(subtype: String, page: ObjectRef, rect: PDFRect, color: RGBColor,
                contents: String?, author: String?, flags: Int) -> PDFDictionary {
        var d: PDFDictionary = [
            "Type": .name("Annot"), "Subtype": .name(PDFName(subtype)),
            "Rect": .array([rect.x, rect.y, rect.maxX, rect.maxY].map(PDFObject.number)),
            "P": .reference(page), "F": .integer(flags),
            "C": .array([color.red, color.green, color.blue].map(PDFObject.number)),
            "NM": .text("lectern-" + UUID().uuidString.lowercased()),
            "M": .text(dateString), "CreationDate": .text(dateString),
        ]
        if let contents { d["Contents"] = .text(contents) }
        if let author, !author.isEmpty { d["T"] = .text(author) }
        return d
    }

    mutating func apply(_ change: AnnotationChange) throws(PDFSaveError) {
        switch change {
        case .addHighlight(let h):
            guard !h.quads.isEmpty else { throw .unsupported("highlight without quads") }
            let pageRef = try doc.pageRef(at: h.pageIndex)
            let points = h.quads.flatMap(\.points)
            let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
            let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
            let rect = PDFRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let ref = try allocate()
            var d = common(subtype: "Highlight", page: pageRef, rect: rect, color: h.color,
                           contents: h.contents, author: h.author, flags: 4)
            d["QuadPoints"] = .array(points.flatMap { [PDFObject.number($0.x), .number($0.y)] })
            if options.appearanceStreams {
                let ap = try allocate()
                written[ap] = .stream(AppearanceStreams.highlight(quads: h.quads, color: h.color, bbox: rect))
                d["AP"] = .dictionary(["N": .reference(ap)])
            }
            written[ref] = .dictionary(d)
            pageAnnots[h.pageIndex] = try annots(h.pageIndex) + [.reference(ref)]
            added.append(ref)

        case .addNote(let n):
            let pageRef = try doc.pageRef(at: n.pageIndex)
            let size = 20.0
            let rect = PDFRect(x: n.origin.x, y: n.origin.y, width: size, height: size)
            let ref = try allocate()
            // Print | NoZoom | NoRotate, as Acrobat and Preview write sticky notes.
            var d = common(subtype: "Text", page: pageRef, rect: rect, color: n.color,
                           contents: n.contents, author: n.author, flags: 28)
            d["Name"] = .name("Comment")
            d["Open"] = .bool(false)
            if options.appearanceStreams {
                let ap = try allocate()
                written[ap] = .stream(AppearanceStreams.note(size: size, color: n.color))
                d["AP"] = .dictionary(["N": .reference(ap)])
            }
            written[ref] = .dictionary(d)
            pageAnnots[n.pageIndex] = try annots(n.pageIndex) + [.reference(ref)]
            added.append(ref)

        case .editContents(let ref, let text):
            _ = try page(of: ref)
            let current: PDFObject
            if let pending = written[ref] { current = pending } else { current = try doc.object(ref) }
            guard case .dictionary(var d) = current, d["Subtype"] != nil else {
                throw .unsupported("\(ref) is not an annotation dictionary")
            }
            guard !d.hasDuplicateKeys else { throw .unsupported("annotation \(ref) has duplicate keys") }
            d["Contents"] = .text(text)
            d["M"] = .text(dateString)
            if d["Subtype"]?.nameValue == "FreeText" {
                // A FreeText appearance (and its rich text) draws the old text. Drop both so viewers
                // regenerate the appearance from /Contents and /DA.
                d["AP"] = nil
                d["RC"] = nil
            }
            written[ref] = .dictionary(d)
            rewritten.insert(ref)
            edited.insert(ref)

        case .delete(let ref):
            let page = try page(of: ref)
            let infos = try doc.annotations(onPage: page)
            // Replies (/IRT) go with the annotation, as in Acrobat, and so do replies to replies.
            var targets: Set<ObjectRef> = [ref]
            var queue = [ref]
            while let current = queue.popLast() {
                for info in infos where info.inReplyTo == current && !targets.contains(info.ref) {
                    targets.insert(info.ref)
                    queue.append(info.ref)
                }
            }
            for info in infos where targets.contains(info.ref) {
                if let popup = info.popup { targets.insert(popup) }
            }
            let before = try annots(page)
            let after = before.filter { item in item.referenceValue.map { !targets.contains($0) } ?? true }
            removed += before.compactMap(\.referenceValue).filter { targets.contains($0) }
            pageAnnots[page] = after
        }
    }

    /// Writes the changed `/Annots` arrays: the indirect array object if there is one, otherwise the page.
    mutating func finishPages() throws(PDFSaveError) {
        for (page, items) in pageAnnots.sorted(by: { $0.key < $1.key }) {
            let location = try doc.annots(ofPage: page)
            guard items != location.items else { continue }
            // An indirect array that only this page uses is rewritten in place. One shared with
            // other pages must not be, or the change would appear on every page: this page gets
            // its own direct array instead.
            if case .indirect(let r, _) = location, try doc.pagesSharing(annotsArray: r) == 1 {
                let ref = try existingRef(r.number)
                written[ref] = .array(items)
                rewritten.insert(ref)
            } else {
                let pageRef = try existingRef(try doc.pageRef(at: page).number)
                guard var dict = try doc.dictionary(pageRef) else { throw .malformed("page \(pageRef) is not a dictionary") }
                guard !dict.hasDuplicateKeys else { throw .unsupported("page \(pageRef) has duplicate keys") }
                dict["Annots"] = .array(items)
                written[pageRef] = .dictionary(dict)
                rewritten.insert(pageRef)
            }
        }
        // An annotation can't be both edited and deleted (or removed as a popup or reply) in one save.
        if let clash = edited.first(where: { removed.contains($0) }) { throw .annotationNotFound(clash) }
        // Edits were keyed with the caller's reference; normalise their generations too.
        for ref in rewritten where written[ref] != nil {
            let fixed = try existingRef(ref.number)
            if fixed != ref, let value = written.removeValue(forKey: ref) {
                written[fixed] = value
                rewritten.remove(ref)
                rewritten.insert(fixed)
            }
        }
    }

    /// The reference to write a replacement under: same number, same generation as the current entry.
    func existingRef(_ number: Int) throws(PDFSaveError) -> ObjectRef {
        switch doc.entry(for: number) {
        case .inUse(_, let gen)?: return ObjectRef(number, gen)
        case .compressed?: return ObjectRef(number, 0)
        default: throw .malformed("object \(number) is not in use")
        }
    }

    func serialize(original: [UInt8]) throws(PDFSaveError) -> SaveResult {
        var out: [UInt8] = []
        if let last = original.last, last != 0x0A, last != 0x0D { out.append(0x0A) }
        var offsets: [ObjectRef: Int] = [:]
        var session = self
        var toWrite = written
        options.testHooks.mutateWritten?(&toWrite)
        let ordered = toWrite.keys.sorted()
        for ref in ordered {
            offsets[ref] = original.count + out.count
            out += Array("\(ref.number) \(ref.generation) obj\n".utf8)
            PDFSerializer.write(toWrite[ref]!, to: &out)
            out += Array("\nendobj\n".utf8)
        }

        var trailer = PDFDictionary()
        let dropped: Set<PDFName> = ["Prev", "XRefStm", "Type", "W", "Index", "Length", "Filter", "DecodeParms",
                                     "F", "FFilter", "FDecodeParms", "DL", "Size", "ID"]
        for entry in doc.trailer.entries where !dropped.contains(entry.key) { trailer[entry.key] = entry.value }
        let fresh = PDFString(bytes: Self.digest(original.count, out), isHex: true)
        var firstID = fresh
        if let ids = doc.trailer["ID"]?.arrayValue, ids.count == 2, let first = ids[0].stringValue { firstID = first }
        trailer["ID"] = .array([.string(firstID), .string(fresh)])
        trailer["Prev"] = .integer(doc.startXRef)

        let kind = doc.latestXRefKind
        let xrefOffset = original.count + out.count
        switch kind {
        case .table:
            trailer["Size"] = .integer(max(doc.size, session.nextNumber))
            out += Array("xref\n".utf8)
            for run in Self.runs(ordered.map(\.number)) {
                out += Array("\(run.first!) \(run.count)\n".utf8)
                for number in run {
                    let ref = ordered.first { $0.number == number }!
                    // Each entry is exactly 20 bytes, ending in CR LF.
                    out += Array(String(format: "%010d %05d n\r\n", offsets[ref]!, ref.generation).utf8)
                }
            }
            out += Array("trailer\n".utf8)
            PDFSerializer.write(trailer, to: &out)
            out += Array("\n".utf8)
        case .stream:
            let xref = try session.allocate()
            offsets[xref] = xrefOffset
            let all = (ordered + [xref]).sorted()
            let maxOffset = offsets.values.max() ?? 0
            var offsetWidth = 1
            while maxOffset >> (8 * offsetWidth) > 0 { offsetWidth += 1 }
            var rows: [UInt8] = []
            var index: [PDFObject] = []
            for run in Self.runs(all.map(\.number)) {
                index += [.integer(run.first!), .integer(run.count)]
                for number in run {
                    let ref = all.first { $0.number == number }!
                    rows.append(1)
                    let off = offsets[ref]!
                    for i in stride(from: offsetWidth - 1, through: 0, by: -1) { rows.append(UInt8((off >> (8 * i)) & 0xFF)) }
                    rows.append(UInt8((ref.generation >> 8) & 0xFF))
                    rows.append(UInt8(ref.generation & 0xFF))
                }
            }
            var dict: PDFDictionary = [
                "Type": .name("XRef"), "Size": .integer(max(doc.size, session.nextNumber)),
                "Index": .array(index), "W": .array([.integer(1), .integer(offsetWidth), .integer(2)]),
            ]
            for entry in trailer.entries { dict[entry.key] = entry.value }
            out += Array("\(xref.number) \(xref.generation) obj\n".utf8)
            PDFSerializer.write(.stream(PDFStream(dictionary: dict, rawData: rows)), to: &out)
            out += Array("\nendobj\n".utf8)
            session.written[xref] = .null  // recorded for the result only
        }
        out += Array("startxref\n\(xrefOffset)\n%%EOF\n".utf8)

        var output = original + out
        options.testHooks.mutateOutput?(&output)
        if options.verify { try verify(output: output, originalCount: original.count) }
        return SaveResult(
            data: Data(output), originalLength: original.count, xrefKind: kind,
            addedAnnotations: added, rewrittenObjects: rewritten.sorted(),
            writtenObjects: Set(toWrite.keys).union(session.written.keys).sorted(), removedAnnotations: removed
        )
    }

    /// Post-write check: the output re-parses with our own reader, the chain points back at the
    /// original, every object we wrote reads back identically, and every page we didn't touch
    /// still resolves to exactly what it was (same page objects, same /Annots, same annotations).
    func verify(output: [UInt8], originalCount: Int) throws(PDFSaveError) {
        do {
            try verifyChecks(output: output, originalCount: originalCount)
        } catch .verificationFailed(let reason) {
            throw .verificationFailed(reason)
        } catch {
            throw .verificationFailed("output does not resolve: \(error)")
        }
    }

    private func verifyChecks(output: [UInt8], originalCount: Int) throws(PDFSaveError) {
        guard output.count > originalCount, Array(output[0..<originalCount]) == doc.bytes else {
            throw .verificationFailed("original bytes are not a prefix of the output")
        }
        let reread = try PDFSaveDocument(bytes: output)
        guard reread.sections.count == doc.sections.count + 1,
              reread.sections[0].trailer["Prev"]?.intValue == doc.startXRef else {
            throw .verificationFailed("new section does not chain to the original")
        }
        guard reread.pageRefs == doc.pageRefs else { throw .verificationFailed("page tree changed") }
        for (ref, object) in written {
            let back = try reread.object(ref)
            guard PDFSerializer.bytes(back) == PDFSerializer.bytes(object) else {
                throw .verificationFailed("object \(ref) does not read back identically")
            }
        }
        func same(_ ref: ObjectRef) throws(PDFSaveError) -> Bool {
            PDFSerializer.bytes(try reread.object(ref)) == PDFSerializer.bytes(try doc.object(ref))
        }
        for (page, pageRef) in doc.pageRefs.enumerated() {
            let expected: [PDFObject]
            if let touched = pageAnnots[page] { expected = touched } else { expected = try doc.annots(ofPage: page).items }
            let actual = try reread.annots(ofPage: page).items
            guard actual == expected else {
                throw .verificationFailed("page \(page + 1) /Annots does not read back as expected")
            }
            if written[pageRef] == nil, !(try same(pageRef)) {
                throw .verificationFailed("untouched page \(page + 1) changed")
            }
            for item in actual {
                guard let ref = item.referenceValue, written[ref] == nil else { continue }
                guard try same(ref) else { throw .verificationFailed("annotation \(ref) on page \(page + 1) changed") }
            }
        }
    }

    static func runs(_ numbers: [Int]) -> [[Int]] {
        var result: [[Int]] = []
        for n in numbers.sorted() {
            if let last = result.last?.last, last + 1 == n { result[result.count - 1].append(n) } else { result.append([n]) }
        }
        return result
    }

    /// A 16-byte identifier for the new revision (two FNV-1a 64 hashes), deterministic per output.
    static func digest(_ originalCount: Int, _ update: [UInt8]) -> [UInt8] {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in withUnsafeBytes(of: originalCount.bigEndian, Array.init) + update {
                h ^= UInt64(b)
                h = h &* 0x100000001b3
            }
            return h
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        return withUnsafeBytes(of: a.bigEndian, Array.init) + withUnsafeBytes(of: b.bigEndian, Array.init)
    }
}
