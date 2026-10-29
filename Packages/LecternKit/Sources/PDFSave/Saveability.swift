import Foundation

/// Why a document may only be saved as a copy (A1). The original is never modified; the copy is
/// the original bytes plus the appended update (`IncrementalWriter.saveCopy`).
public enum CopyOnlyReason: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Comparable {
    /// A certification signature (`/Perms /DocMDP`). Adding annotations can break the
    /// certification, depending on its permission level.
    case certified
    /// Reader-extended usage rights (`/Perms /UR3` or `/UR`). Adobe Reader drops the extended
    /// rights once the file changes.
    case readerExtended
    /// A filled signature field (`/FT /Sig` with a `/V`). The signature stays valid for its own
    /// revision, but a viewer reports the changes made after it.
    case signed
    /// The file's location can't be written. Only the app knows this; it passes it in.
    case readOnlyLocation

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Why a document can't be saved with annotations at all, not even as a copy.
public enum UnsupportedReason: Sendable, Equatable, Hashable {
    /// Encrypted files can't be saved with annotations in v1 (architecture §4.3).
    case encrypted
    /// The structure can't be trusted; the writer never repairs.
    case malformed(String)
    /// Valid, but uses structure the writer deliberately doesn't handle (data before `%PDF-`,
    /// non-Flate cross-reference streams, …).
    case unsupportedStructure(String)
}

/// Whether a file can be saved where it is (A1).
public enum Saveability: Sendable, Equatable, Hashable {
    case inPlace
    /// Every reason that applies, in `CopyOnlyReason` order; never empty.
    case copyOnly([CopyOnlyReason])
    case unsupported(UnsupportedReason)

    /// Checks `data`: parses the cross-reference chain and page tree, reads every page's
    /// annotations, and looks for signatures, `/Perms` and encryption. `readOnlyLocation` comes
    /// from the app (sandbox access, locked file, read-only volume).
    public static func evaluate(_ data: Data, readOnlyLocation: Bool = false) -> Saveability {
        do throws(PDFSaveError) {
            let doc = try PDFSaveDocument(data: data)
            return try doc.saveability(readOnlyLocation: readOnlyLocation)
        } catch {
            return .unsupported(UnsupportedReason(error))
        }
    }
}

extension UnsupportedReason {
    init(_ error: PDFSaveError) {
        switch error {
        case .encrypted: self = .encrypted
        case .unsupported(let why): self = .unsupportedStructure(why)
        case .malformed(let why): self = .malformed(why)
        default: self = .malformed("\(error)")
        }
    }
}

extension PDFSaveDocument {
    /// The structural check behind `Saveability.evaluate`. Throws for a file whose pages or
    /// annotations don't resolve.
    public func saveability(readOnlyLocation: Bool = false) throws(PDFSaveError) -> Saveability {
        for page in 0..<pageCount { _ = try annotations(onPage: page) }
        var reasons = copyOnlyReasons
        if readOnlyLocation { reasons.append(.readOnlyLocation) }
        return reasons.isEmpty ? .inPlace : .copyOnly(reasons.sorted())
    }

    /// The document-level reasons to save only as a copy (everything except the location).
    public var copyOnlyReasons: [CopyOnlyReason] {
        var reasons: [CopyOnlyReason] = []
        if isCertified { reasons.append(.certified) }
        if isReaderExtended { reasons.append(.readerExtended) }
        if isSigned { reasons.append(.signed) }
        return reasons
    }

    var catalog: PDFDictionary? {
        guard let rootRef = trailer["Root"]?.referenceValue else { return nil }
        return try? dictionary(rootRef)
    }

    private var perms: PDFDictionary? {
        guard let p = catalog?["Perms"] else { return nil }
        return (try? resolve(p))?.dictionaryValue
    }

    /// `/Perms /DocMDP`: a certification signature.
    public var isCertified: Bool { perms?["DocMDP"] != nil }

    /// `/Perms /UR3` (or the older `/UR`): Reader-extended usage rights.
    public var isReaderExtended: Bool { perms?["UR3"] != nil || perms?["UR"] != nil }

    /// True when a signature field in the AcroForm has a value. `/FT` is inheritable, so it is
    /// tracked down the `/Kids` tree. An empty signature field doesn't count.
    public var isSigned: Bool {
        guard let acroForm = catalog?["AcroForm"].flatMap({ try? resolve($0) })?.dictionaryValue,
              let fields = (try? resolve(acroForm["Fields"] ?? .null))?.arrayValue else { return false }
        var visited = Set<ObjectRef>()
        func signed(_ item: PDFObject, inheritedType: PDFName?, depth: Int) -> Bool {
            guard depth < 32 else { return false }
            if let ref = item.referenceValue, !visited.insert(ref).inserted { return false }
            guard let field = (try? resolve(item))?.dictionaryValue else { return false }
            let type = field["FT"]?.nameValue ?? inheritedType
            if type == "Sig", let v = field["V"], (try? resolve(v))?.dictionaryValue != nil { return true }
            let kids = (try? resolve(field["Kids"] ?? .null))?.arrayValue ?? []
            return kids.contains { signed($0, inheritedType: type, depth: depth + 1) }
        }
        return fields.contains { signed($0, inheritedType: nil, depth: 0) }
    }
}
