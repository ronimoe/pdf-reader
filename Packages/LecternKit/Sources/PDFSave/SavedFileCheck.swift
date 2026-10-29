import Foundation

/// The check after a save has written its file (A1): the bytes read back from disk are exactly the
/// bytes the writer produced, they re-parse, and the annotations they contain are the original's
/// plus the added ones minus the removed ones, with every added `/NM` on the expected object.
///
/// Counting isn't enough for an encrypted file: strings encrypted with a wrong key still give the
/// right number of annotations, with garbage text. So every annotation's subtype, `/NM` and
/// `/Contents` are compared too, read through the same decryption a reader would use: the added
/// and edited ones against what the writer meant to write, every other one against the original.
public enum SavedFileCheck {
    /// Throws `.verificationFailed` with a reason a person can read. Returns the saved file's
    /// annotations, which the app matches against from now on. `password` opens an encrypted
    /// file (the session password, or nil for the empty one), as for the save itself.
    @discardableResult
    public static func verify(_ written: Data, original: Data, against result: SaveResult,
                              password: String? = nil) throws(PDFSaveError) -> [AnnotationDescriptor] {
        guard written == result.data else {
            throw .verificationFailed("the file on disk differs from the bytes that were written (\(written.count) bytes read, \(result.data.count) expected)")
        }
        guard result.originalLength == original.count, written.count >= original.count, written.prefix(original.count) == original else {
            throw .verificationFailed("the original bytes are not a prefix of the saved file")
        }
        let before: [AnnotationDescriptor]
        let after: [AnnotationDescriptor]
        do throws(PDFSaveError) {
            let originalDocument = try PDFSaveDocument(data: original, password: password)
            let savedDocument = try PDFSaveDocument(data: written, password: password)
            guard originalDocument.isEncrypted == result.isEncrypted, savedDocument.isEncrypted == result.isEncrypted,
                  savedDocument.fileEncryptionKey == originalDocument.fileEncryptionKey else {
                throw PDFSaveError.verificationFailed("the saved file's encryption differs from the original's")
            }
            before = try originalDocument.annotations()
            after = try savedDocument.annotations()
        } catch .verificationFailed(let why) {
            throw .verificationFailed(why)
        } catch {
            throw .verificationFailed("the saved file doesn't re-read: \(error)")
        }
        let removed = Set(result.removedAnnotations)
        let expectedCount = before.count + result.added.count - before.filter { $0.ref.map(removed.contains) ?? false }.count
        guard after.count == expectedCount else {
            throw .verificationFailed("the saved file has \(after.count) annotations, \(expectedCount) expected")
        }
        for added in result.added {
            let named = after.filter { $0.name == added.name }
            guard named.count == 1, named[0].ref == added.ref, named[0].pageIndex == added.pageIndex else {
                throw .verificationFailed("added annotation \(added.name) is missing or misplaced")
            }
        }
        if let stray = after.first(where: { $0.ref.map(removed.contains) ?? false }) {
            throw .verificationFailed("deleted annotation \(stray.ref.map(String.init(describing:)) ?? "?") is still listed")
        }
        // What every annotation must read back as.
        var original: [ObjectRef: AnnotationDescriptor] = [:]
        for d in before { if let ref = d.ref, original[ref] == nil { original[ref] = d } }
        func same(_ a: String?, _ b: String?) -> Bool { (a ?? "") == (b ?? "") }
        for d in after {
            guard let ref = d.ref else { continue }  // inline dictionaries are never written
            if let expected = result.writtenAnnotations[ref] {
                guard d.subtype == expected.subtype, d.name == expected.name, same(d.contents, expected.contents) else {
                    throw .verificationFailed("annotation \(ref) doesn't read back as written")
                }
            } else if let old = original[ref] {
                guard d.subtype == old.subtype, d.name == old.name, same(d.contents, old.contents), d.author == old.author else {
                    throw .verificationFailed("annotation \(ref) reads back differently from the original")
                }
            } else {
                throw .verificationFailed("annotation \(ref) appeared without being added")
            }
        }
        return after
    }
}
