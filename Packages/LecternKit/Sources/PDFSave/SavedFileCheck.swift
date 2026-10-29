import Foundation

/// The check after a save has written its file (A1): the bytes read back from disk are exactly the
/// bytes the writer produced, they re-parse, and the annotations they contain are the original's
/// plus the added ones minus the removed ones, with every added `/NM` on the expected object.
public enum SavedFileCheck {
    /// Throws `.verificationFailed` with a reason a person can read. Returns the saved file's
    /// annotations, which the app matches against from now on.
    @discardableResult
    public static func verify(_ written: Data, original: Data, against result: SaveResult) throws(PDFSaveError) -> [AnnotationDescriptor] {
        guard written == result.data else {
            throw .verificationFailed("the file on disk differs from the bytes that were written (\(written.count) bytes read, \(result.data.count) expected)")
        }
        guard result.originalLength == original.count, written.count >= original.count, written.prefix(original.count) == original else {
            throw .verificationFailed("the original bytes are not a prefix of the saved file")
        }
        let before: [AnnotationDescriptor]
        let after: [AnnotationDescriptor]
        do throws(PDFSaveError) {
            before = try PDFSaveDocument(data: original).annotations()
            after = try PDFSaveDocument(data: written).annotations()
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
        return after
    }
}
