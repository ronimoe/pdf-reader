import Foundation

public enum XRefKind: String, Sendable {
    /// A classic `xref` table (including hybrid files whose table points at an `/XRefStm`).
    case table
    /// A cross-reference stream (`/Type /XRef`).
    case stream
}

enum XRefEntry: Equatable {
    case free
    case inUse(offset: Int, generation: Int)
    case compressed(stream: Int, index: Int)
}

/// One section of the cross-reference chain, newest first.
struct XRefSection {
    let offset: Int
    let kind: XRefKind
    let trailer: PDFDictionary
    let hybridStreamOffset: Int?
}

/// A read-only, structural view of a PDF file: its cross-reference chain, objects and pages.
/// It reads only what the incremental writer needs and never repairs a damaged file.
public final class PDFSaveDocument {
    /// Upper bound on object numbers and cross-reference entries. Anything larger is treated as
    /// damage rather than allocated.
    static let maxObjects = 10_000_000

    let bytes: [UInt8]
    private(set) var entries: [Int: XRefEntry] = [:]
    private(set) var sections: [XRefSection] = []
    /// Offset that the last `startxref` points at; the new section's `/Prev`.
    public let startXRef: Int
    public private(set) var trailer = PDFDictionary()
    public private(set) var size = 0
    public private(set) var pageRefs: [ObjectRef] = []

    private var cache: [Int: PDFObject] = [:]
    private var objectStreams: [Int: [Int: PDFObject]] = [:]
    private var resolving = Set<Int>()

    public var latestXRefKind: XRefKind { sections[0].kind }
    public var pageCount: Int { pageRefs.count }
    public var isHybrid: Bool { sections.contains { $0.hybridStreamOffset != nil } }
    public var revisionCount: Int { sections.count }

    public convenience init(data: Data) throws(PDFSaveError) {
        try self.init(bytes: [UInt8](data))
    }

    init(bytes: [UInt8]) throws(PDFSaveError) {
        self.bytes = bytes
        guard let header = PDFParser.find(Array("%PDF-".utf8), in: Array(bytes.prefix(1024)), from: 0) else {
            throw .malformed("no %PDF- header")
        }
        // Offsets in files with leading garbage are ambiguous; the writer won't guess.
        guard header == 0 else { throw .unsupported("data before the %PDF- header") }
        startXRef = try Self.findStartXRef(bytes)
        try readChain()
        if trailer["Encrypt"] != nil || sections.contains(where: { $0.trailer["Encrypt"] != nil }) {
            throw .encrypted
        }
        guard trailer["Root"]?.referenceValue != nil else { throw .malformed("trailer has no /Root reference") }
        pageRefs = try collectPages()
    }

    // MARK: Cross-reference chain

    static func findStartXRef(_ bytes: [UInt8]) throws(PDFSaveError) -> Int {
        let tail = Array(bytes.suffix(2048))
        guard let at = PDFParser.findLast(Array("startxref".utf8), in: tail) else {
            throw .malformed("no startxref near end of file")
        }
        var p = PDFParser(bytes: tail, pos: at + "startxref".utf8.count)
        let offset = try p.readInteger()
        guard offset > 0, offset < bytes.count else { throw .malformed("startxref \(offset) out of range") }
        return offset
    }

    private func readChain() throws(PDFSaveError) {
        var next: Int? = startXRef
        var visited = Set<Int>()
        while let offset = next {
            guard visited.insert(offset).inserted else { throw .malformed("/Prev loop at \(offset)") }
            guard offset > 0, offset < bytes.count else { throw .malformed("xref offset \(offset) out of range") }
            var p = PDFParser(bytes: bytes, pos: offset)
            p.skipWhitespace()
            guard p.pos == offset else { throw .malformed("xref offset \(offset) does not point at a section") }
            var sectionEntries: [Int: XRefEntry]
            let section: XRefSection
            if p.peekKeyword("xref") {
                let (e, trailerDict) = try readTable(at: offset)
                sectionEntries = e
                var hybrid: Int?
                if let stm = trailerDict["XRefStm"] {
                    guard let x = stm.intValue, x > 0, x < bytes.count, x != offset else {
                        throw .malformed("/XRefStm out of range in section at \(offset)")
                    }
                    // Hybrid file: the table's own entries win; the stream fills in the rest.
                    let (streamEntries, _) = try readXRefStream(at: x)
                    for (num, entry) in streamEntries where sectionEntries[num] == nil {
                        sectionEntries[num] = entry
                    }
                    hybrid = x
                }
                section = XRefSection(offset: offset, kind: .table, trailer: trailerDict, hybridStreamOffset: hybrid)
            } else {
                let (e, dict) = try readXRefStream(at: offset)
                sectionEntries = e
                section = XRefSection(offset: offset, kind: .stream, trailer: dict, hybridStreamOffset: nil)
            }
            // Newer sections win, including their free entries.
            for (num, entry) in sectionEntries where entries[num] == nil { entries[num] = entry }
            sections.append(section)
            guard let sectionSize = section.trailer["Size"]?.intValue, sectionSize >= 0,
                  sectionSize <= Self.maxObjects else {
                throw .malformed("missing or out-of-range /Size in section at \(offset)")
            }
            size = max(size, sectionSize)
            switch section.trailer["Prev"] {
            case nil: next = nil
            case let prev?:
                guard let p = prev.intValue else { throw .malformed("non-integer /Prev in section at \(offset)") }
                next = p
            }
        }
        size = max(size, (entries.keys.max() ?? 0) + 1)
        guard size <= Self.maxObjects else { throw .malformed("more than \(Self.maxObjects) objects") }
        // The update trailer copies the newest trailer's keys; fall back to older ones for
        // /Root, /Info and /ID if a sloppy writer left them out of the newest.
        trailer = sections[0].trailer
        for key: PDFName in ["Root", "Info", "ID"] where trailer[key] == nil {
            if let v = sections.lazy.compactMap({ $0.trailer[key] }).first { trailer[key] = v }
        }
    }

    private func readTable(at offset: Int) throws(PDFSaveError) -> ([Int: XRefEntry], PDFDictionary) {
        var p = PDFParser(bytes: bytes, pos: offset)
        try p.expectKeyword("xref")
        var result: [Int: XRefEntry] = [:]
        while true {
            p.skipWhitespace()
            if p.peekKeyword("trailer") { break }
            let start = try p.readInteger()
            let count = try p.readInteger()
            guard start >= 0, count >= 0, start <= Self.maxObjects, count <= Self.maxObjects - start else {
                throw p.fail("bad xref subsection \(start) \(count)")
            }
            for i in 0..<count {
                let field1 = try p.readInteger()
                let field2 = try p.readInteger()
                p.skipWhitespace()
                let type = p.readToken()
                switch type {
                case Array("n".utf8):
                    if result[start + i] == nil { result[start + i] = .inUse(offset: field1, generation: field2) }
                case Array("f".utf8):
                    if result[start + i] == nil { result[start + i] = .free }
                default:
                    throw p.fail("bad xref entry type")
                }
            }
        }
        try p.expectKeyword("trailer")
        guard case .dictionary(let dict) = try p.parseObject() else { throw p.fail("trailer is not a dictionary") }
        return (result, dict)
    }

    private func readXRefStream(at offset: Int) throws(PDFSaveError) -> ([Int: XRefEntry], PDFDictionary) {
        var p = PDFParser(bytes: bytes, pos: offset, lengthResolver: nil)
        let (_, object) = try p.parseIndirectObject()
        guard case .stream(let stream) = object, stream.dictionary["Type"]?.nameValue == "XRef" else {
            throw .malformed("offset \(offset) is not a cross-reference stream")
        }
        let dict = stream.dictionary
        let data = try StreamDecoder.decode(stream)
        guard let w = dict["W"]?.arrayValue?.compactMap(\.intValue), w.count == 3, w.allSatisfy({ $0 >= 0 && $0 <= 8 }) else {
            throw .malformed("bad /W in cross-reference stream")
        }
        let streamSize = dict["Size"]?.intValue ?? 0
        let index = dict["Index"]?.arrayValue?.compactMap(\.intValue) ?? [0, streamSize]
        guard index.count % 2 == 0 else { throw .malformed("bad /Index in cross-reference stream") }
        let rowWidth = w.reduce(0, +)
        guard rowWidth > 0 else { throw .malformed("zero-width cross-reference rows") }
        var result: [Int: XRefEntry] = [:]
        var cursor = 0
        func field(_ width: Int, default value: Int) -> Int {
            guard width > 0 else { return value }
            var v = 0
            for _ in 0..<width { v = v << 8 | Int(data[cursor]); cursor += 1 }
            return v
        }
        for pair in stride(from: 0, to: index.count, by: 2) {
            let first = index[pair], count = index[pair + 1]
            guard first >= 0, count >= 0, first <= Self.maxObjects, count <= Self.maxObjects - first else {
                throw .malformed("bad /Index entry \(first) \(count) in cross-reference stream")
            }
            for i in 0..<count {
                guard cursor + rowWidth <= data.count else { throw .malformed("cross-reference stream too short") }
                let type = field(w[0], default: 1)
                let f2 = field(w[1], default: 0)
                let f3 = field(w[2], default: 0)
                let entry: XRefEntry? = switch type {
                case 0: .free
                case 1: .inUse(offset: f2, generation: f3)
                case 2: .compressed(stream: f2, index: f3)
                default: nil  // Unknown types are treated as null references (ISO 32000 7.5.8.3).
                }
                if let entry, result[first + i] == nil { result[first + i] = entry }
            }
        }
        return (result, dict)
    }

    // MARK: Objects

    func entry(for number: Int) -> XRefEntry? { entries[number] }

    /// Returns the object with this number, or `.null` if it is free or missing.
    public func object(_ ref: ObjectRef) throws(PDFSaveError) -> PDFObject {
        if let cached = cache[ref.number] { return cached }
        guard resolving.insert(ref.number).inserted else { throw .malformed("reference cycle at \(ref)") }
        defer { resolving.remove(ref.number) }
        let object: PDFObject
        switch entries[ref.number] {
        case nil, .free?:
            object = .null
        case .inUse(let offset, let generation)?:
            guard offset > 0, offset < bytes.count else { throw .malformed("object \(ref) offset out of range") }
            var p = PDFParser(bytes: bytes, pos: offset) { [unowned self] r in
                try? self.resolve(.reference(r)).intValue
            }
            let (found, parsed) = try p.parseIndirectObject()
            // The cross-reference must point exactly at the object it names. A mismatch means the
            // table is stale, and writing on top of it would compound the damage.
            guard found.number == ref.number, found.generation == generation else {
                throw .malformed("xref entry for \(ref.number) points at object \(found)")
            }
            object = parsed
        case .compressed(let stream, let index)?:
            object = try compressedObject(ref.number, in: stream, index: index)
        }
        cache[ref.number] = object
        return object
    }

    private func compressedObject(_ number: Int, in streamNumber: Int, index: Int) throws(PDFSaveError) -> PDFObject {
        if objectStreams[streamNumber] == nil {
            guard case .stream(let stream) = try object(ObjectRef(streamNumber, 0)),
                  stream.dictionary["Type"]?.nameValue == "ObjStm" else {
                throw .malformed("object \(streamNumber) is not an object stream")
            }
            guard let n = stream.dictionary["N"]?.intValue, let first = stream.dictionary["First"]?.intValue,
                  n >= 0, first >= 0, n <= Self.maxObjects else { throw .malformed("object stream \(streamNumber) lacks /N or /First") }
            let data = try StreamDecoder.decode(stream)
            var header = PDFParser(bytes: data)
            var pairs: [(Int, Int)] = []
            for _ in 0..<n { pairs.append((try header.readInteger(), try header.readInteger())) }
            var objects: [Int: PDFObject] = [:]
            for (num, off) in pairs {
                guard off >= 0, num >= 0, first < data.count, off < data.count - first else { throw .malformed("object stream \(streamNumber) offset out of range") }
                var p = PDFParser(bytes: data, pos: first + off)
                objects[num] = try p.parseObject()
            }
            objectStreams[streamNumber] = objects
        }
        guard let object = objectStreams[streamNumber]?[number] else {
            throw .malformed("object \(number) missing from object stream \(streamNumber) (index \(index))")
        }
        return object
    }

    /// Follows references until a direct object is reached.
    public func resolve(_ object: PDFObject) throws(PDFSaveError) -> PDFObject {
        var current = object
        var hops = 0
        while case .reference(let r) = current {
            hops += 1
            guard hops < 32 else { throw .malformed("reference chain too long at \(r)") }
            current = try self.object(r)
        }
        return current
    }

    public func dictionary(_ ref: ObjectRef) throws(PDFSaveError) -> PDFDictionary? {
        try object(ref).dictionaryValue
    }

    // MARK: Pages

    private func collectPages() throws(PDFSaveError) -> [ObjectRef] {
        guard let rootRef = trailer["Root"]?.referenceValue,
              let root = try dictionary(rootRef),
              let pagesRef = root["Pages"]?.referenceValue else {
            throw .malformed("catalog has no /Pages reference")
        }
        var result: [ObjectRef] = []
        var visited = Set<ObjectRef>()
        func walk(_ ref: ObjectRef, depth: Int) throws(PDFSaveError) {
            guard depth < 64, visited.insert(ref).inserted else { throw .malformed("page tree loop at \(ref)") }
            guard let node = try dictionary(ref) else { throw .malformed("page tree node \(ref) is not a dictionary") }
            let type = node["Type"]?.nameValue
            if type == "Pages" || (type == nil && node["Kids"] != nil) {
                guard let kids = try resolve(node["Kids"] ?? .null).arrayValue else {
                    throw .malformed("page tree node \(ref) has no /Kids array")
                }
                for kid in kids {
                    guard let kidRef = kid.referenceValue else { throw .malformed("direct page object in /Kids of \(ref)") }
                    try walk(kidRef, depth: depth + 1)
                }
            } else {
                result.append(ref)
            }
        }
        try walk(pagesRef, depth: 0)
        return result
    }

    public func pageRef(at index: Int) throws(PDFSaveError) -> ObjectRef {
        guard pageRefs.indices.contains(index) else { throw .pageOutOfRange(index) }
        return pageRefs[index]
    }

    /// The page's `/Annots` entry, resolved.
    enum AnnotsLocation: Equatable {
        case absent
        case direct([PDFObject])
        case indirect(ObjectRef, [PDFObject])

        var items: [PDFObject] {
            switch self {
            case .absent: []
            case .direct(let a), .indirect(_, let a): a
            }
        }
    }

    func annots(ofPage index: Int) throws(PDFSaveError) -> AnnotsLocation {
        let ref = try pageRef(at: index)
        guard let page = try dictionary(ref) else { throw .malformed("page \(ref) is not a dictionary") }
        switch page["Annots"] {
        case nil, .null?: return .absent
        case .array(let a)?: return .direct(a)
        case .reference(let r)?:
            switch try object(r) {
            case .null: return .absent
            case .array(let a): return .indirect(r, a)
            default: throw .malformed("/Annots of page \(ref) is not an array")
            }
        default: throw .malformed("/Annots of page \(ref) is not an array")
        }
    }

    /// How many pages point at this indirect `/Annots` array object.
    func pagesSharing(annotsArray ref: ObjectRef) throws(PDFSaveError) -> Int {
        var count = 0
        for pageRef in pageRefs {
            if try dictionary(pageRef)?["Annots"]?.referenceValue?.number == ref.number { count += 1 }
        }
        return count
    }

    /// The annotations listed on a page, in `/Annots` order, including inline dictionaries
    /// (whose `ref` is nil). Items that aren't dictionaries (null, dangling references) are skipped.
    public func annotations(onPage index: Int) throws(PDFSaveError) -> [AnnotationDescriptor] {
        var result: [AnnotationDescriptor] = []
        for (position, item) in try annots(ofPage: index).items.enumerated() {
            let ref = item.referenceValue
            guard let dict = try resolve(item).dictionaryValue else { continue }
            func text(_ key: PDFName) throws(PDFSaveError) -> String? {
                try resolve(dict[key] ?? .null).stringValue?.text
            }
            let numbers = try resolve(dict["Rect"] ?? .null).arrayValue?.compactMap(\.doubleValue) ?? []
            let rect = numbers.count == 4 ? PDFRect(corners: numbers[0], numbers[1], numbers[2], numbers[3]) : nil
            let components = try resolve(dict["C"] ?? .null).arrayValue?.compactMap(\.doubleValue)
            result.append(AnnotationDescriptor(
                ref: ref, pageIndex: index, indexInAnnots: position,
                // Resolved: `/Subtype 5 0 R` is legal, and PDFKit follows it.
                subtype: try resolve(dict["Subtype"] ?? .null).nameValue?.string ?? "",
                rect: rect, name: try text("NM"), contents: try text("Contents"), author: try text("T"),
                inReplyTo: dict["IRT"]?.referenceValue, popup: dict["Popup"]?.referenceValue,
                color: components.flatMap(AnnotationColor.init(components:))
            ))
        }
        return result
    }

    /// Every page's annotations, page by page.
    public func annotations() throws(PDFSaveError) -> [AnnotationDescriptor] {
        var all: [AnnotationDescriptor] = []
        for page in 0..<pageCount { all += try annotations(onPage: page) }
        return all
    }
}
