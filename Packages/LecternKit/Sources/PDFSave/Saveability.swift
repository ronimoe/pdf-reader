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
    /// Encrypted in a way the writer doesn't handle (R5, a public-key or custom handler, an
    /// unknown crypt filter), or no password Lectern holds authenticates (architecture §4.3).
    case encrypted(EncryptionProblem)
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
    /// from the app (sandbox access, locked file, read-only volume). An encrypted file is read with
    /// `password`, or the empty password (`PDFSaveDocument.init(data:password:)`).
    public static func evaluate(_ data: Data, readOnlyLocation: Bool = false, password: String? = nil) -> Saveability {
        do throws(PDFSaveError) {
            let doc = try PDFSaveDocument(data: data, password: password)
            return try doc.saveability(readOnlyLocation: readOnlyLocation)
        } catch {
            return .unsupported(UnsupportedReason(error))
        }
    }
}

extension UnsupportedReason {
    init(_ error: PDFSaveError) {
        switch error {
        case .encrypted(let problem): self = .encrypted(problem)
        case .unsupported(let why): self = .unsupportedStructure(why)
        case .malformed(let why): self = .malformed(why)
        default: self = .malformed("\(error)")
        }
    }
}

extension PDFSaveDocument {
    /// The structural check behind `Saveability.evaluate`. Throws for a file whose pages,
    /// annotations, signature fields or `/Perms` don't resolve.
    public func saveability(readOnlyLocation: Bool = false) throws(PDFSaveError) -> Saveability {
        for page in 0..<pageCount { _ = try annotations(onPage: page) }
        var reasons = try copyOnlyReasons()
        if readOnlyLocation { reasons.append(.readOnlyLocation) }
        return reasons.isEmpty ? .inPlace : .copyOnly(reasons.sorted())
    }

    /// The document-level reasons to save only as a copy (everything except the location).
    ///
    /// Anything that can't be read while deciding throws `.malformed`: a file whose signatures
    /// or permissions can't be established is never treated as unsigned.
    ///
    /// - **certified:** `/Perms /DocMDP`, or a signature whose `/Reference` has a DocMDP transform.
    /// - **readerExtended:** `/Perms /UR3` or `/UR`, or a signature with a UR3/UR transform.
    /// - **signed:** a signature field with a value, found through the AcroForm `/Fields` tree
    ///   or through any page's Widget annotations (following `/Parent` for an inherited `/FT` and
    ///   `/V`). Also when `/SigFlags` has bit 1 (SignaturesExist) set, unless at least one signature
    ///   field was found and every one is provably empty.
    public func copyOnlyReasons() throws(PDFSaveError) -> [CopyOnlyReason] {
        do throws(PDFSaveError) {
            return try readCopyOnlyReasons()
        } catch .malformed(let why) {
            throw .malformed(why)
        } catch {
            throw .malformed("signature or permission check: \(error)")
        }
    }

    private func readCopyOnlyReasons() throws(PDFSaveError) -> [CopyOnlyReason] {
        var reasons = Set<CopyOnlyReason>()
        guard let rootRef = trailer["Root"]?.referenceValue,
              let catalog = try dictionary(rootRef) else { throw .malformed("catalog is not a dictionary") }

        if let p = catalog["Perms"] {
            switch try resolve(p) {
            case .null: break
            case .dictionary(let perms):
                if perms["DocMDP"] != nil { reasons.insert(.certified) }
                if perms["UR3"] != nil || perms["UR"] != nil { reasons.insert(.readerExtended) }
            default: throw .malformed("/Perms is not a dictionary")
            }
        }

        let signatures = try signatureFields(catalog: catalog)
        for value in signatures.values {
            switch try resolve(value) {
            case .null: continue  // provably empty
            case .dictionary(let sig):
                reasons.insert(.signed)
                for item in try resolve(sig["Reference"] ?? .null).arrayValue ?? [] {
                    switch try resolve(item).dictionaryValue?["TransformMethod"]?.nameValue?.string {
                    case "DocMDP"?: reasons.insert(.certified)
                    case "UR3"?, "UR"?: reasons.insert(.readerExtended)
                    default: break
                    }
                }
            default:
                reasons.insert(.signed)  // a value we can't read is not proof of an empty field
            }
        }
        if signatures.flags & 1 != 0, !reasons.contains(.signed) {
            // SignaturesExist, but no signed field: only "every field provably empty" clears it.
            if signatures.fieldCount == 0 { reasons.insert(.signed) }
        }
        return reasons.sorted()
    }

    /// Every signature field's `/V` (`.null` when absent), from the AcroForm tree and from the
    /// pages' Widgets, plus the AcroForm's `/SigFlags`.
    private func signatureFields(catalog: PDFDictionary) throws(PDFSaveError) -> (values: [PDFObject], fieldCount: Int, flags: Int) {
        var values: [PDFObject] = []
        var seen = Set<ObjectRef>()
        var flags = 0

        func record(_ ref: ObjectRef?, _ value: PDFObject) {
            if let ref, !seen.insert(ref).inserted { return }
            values.append(value)
        }

        var acroForm: PDFDictionary?
        if let a = catalog["AcroForm"] {
            switch try resolve(a) {
            case .null: break
            case .dictionary(let d): acroForm = d
            default: throw .malformed("/AcroForm is not a dictionary")
            }
        }
        if let acroForm {
            if let f = acroForm["SigFlags"] {
                switch try resolve(f) {
                case .null: break
                case let v: guard let i = v.intValue else { throw .malformed("/SigFlags is not an integer") }; flags = i
                }
            }
            let fields: [PDFObject]
            switch try resolve(acroForm["Fields"] ?? .null) {
            case .null: fields = []
            case .array(let a): fields = a
            default: throw .malformed("/Fields is not an array")
            }
            var visited = Set<ObjectRef>()
            func walk(_ item: PDFObject, type: PDFName?, value: PDFObject?, depth: Int) throws(PDFSaveError) {
                guard depth < 32 else { throw .malformed("field tree deeper than 32") }
                if let ref = item.referenceValue, !visited.insert(ref).inserted { return }
                let field: PDFDictionary
                switch try resolve(item) {
                case .null: return
                case .dictionary(let d): field = d
                default: throw .malformed("form field is not a dictionary")
                }
                let ft = field["FT"]?.nameValue ?? type
                let v = field["V"] ?? value
                let kids: [PDFObject]
                switch try resolve(field["Kids"] ?? .null) {
                case .null: kids = []
                case .array(let a): kids = a
                default: throw .malformed("field /Kids is not an array")
                }
                if ft == "Sig", kids.isEmpty || v != nil { record(item.referenceValue, v ?? .null) }
                for kid in kids { try walk(kid, type: ft, value: v, depth: depth + 1) }
            }
            for field in fields { try walk(field, type: nil, value: nil, depth: 0) }
        }

        // Widgets on the pages, which a sloppy writer may have left out of /Fields.
        for page in 0..<pageCount {
            for item in try annots(ofPage: page).items {
                guard let widget = try resolve(item).dictionaryValue, widget["Subtype"]?.nameValue == "Widget" else { continue }
                var ft = widget["FT"]?.nameValue, v = widget["V"]
                var parent = widget["Parent"]
                var hops = 0
                while ft == nil || v == nil, let p = parent, p != .null {
                    hops += 1
                    guard hops < 32 else { throw .malformed("/Parent chain longer than 32") }
                    guard let d = try resolve(p).dictionaryValue else { throw .malformed("widget /Parent is not a dictionary") }
                    ft = ft ?? d["FT"]?.nameValue
                    v = v ?? d["V"]
                    parent = d["Parent"]
                }
                if ft == "Sig" { record(item.referenceValue, v ?? .null) }
            }
        }
        return (values, values.count, flags)
    }
}

