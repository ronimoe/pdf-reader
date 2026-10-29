import CoreGraphics
import Foundation

/// The pages' labels, and how typed input maps to a page (go to page, spec
/// §5.2).
///
/// A document can define its own labels in the catalog's `/PageLabels`
/// (front matter in roman numerals, say). PDFKit makes up "1", "2"… when it
/// doesn't, so whether the document defines them is read from the catalog.
public struct PageNumbering: Hashable, Sendable {
    /// One label per page.
    public let labels: [String]
    /// True when the catalog has `/PageLabels`.
    public let definesLabels: Bool

    public init(labels: [String], definesLabels: Bool) {
        self.labels = labels
        self.definesLabels = definesLabels
    }

    /// Plain numbering, "1" to "pageCount".
    public init(pageCount: Int) {
        self.init(labels: (0..<max(0, pageCount)).map { String($0 + 1) }, definesLabels: false)
    }

    public var pageCount: Int { labels.count }

    /// The label shown for a page: its own label when the document defines
    /// one, otherwise its number.
    public func label(forPageAt index: Int) -> String {
        guard labels.indices.contains(index) else { return String(index + 1) }
        let label = labels[index]
        return label.isEmpty ? String(index + 1) : label
    }

    /// "Page iv (6 of 300)" when labels differ from numbers, "Page 6 of 300" otherwise.
    public func description(forPageAt index: Int) -> String {
        let label = label(forPageAt: index)
        let number = String(index + 1)
        return label == number ? "Page \(number) of \(pageCount)" : "Page \(label) (\(number) of \(pageCount))"
    }

    public enum InputError: Error, Equatable, Sendable {
        case empty
        case noSuchPage(String)
    }

    /// The page index for what the user typed. A label the document defines
    /// wins (ignoring case); otherwise a number from 1 to the page count is
    /// the physical page.
    public func pageIndex(for input: String) -> Result<Int, InputError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if definesLabels,
           let index = labels.firstIndex(where: { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            return .success(index)
        }
        if let number = Int(trimmed), (1...max(1, pageCount)).contains(number), pageCount > 0 {
            return .success(number - 1)
        }
        return .failure(.noSuchPage(trimmed))
    }

    /// What to tell the user when input doesn't name a page.
    public func message(for error: InputError) -> String {
        let range = "a page number from 1 to \(pageCount)"
        switch error {
        case .empty:
            return definesLabels ? "Enter a page label or \(range)." : "Enter \(range)."
        case .noSuchPage(let input):
            return definesLabels
                ? "There’s no page “\(input)”. Enter a page label, such as “\(label(forPageAt: 0))”, or \(range)."
                : "There’s no page “\(input)”. Enter \(range)."
        }
    }

    /// Whether the catalog defines `/PageLabels`. A locked document reads as
    /// false.
    public static func definesPageLabels(_ document: CGPDFDocument) -> Bool {
        guard document.isUnlocked, let catalog = document.catalog else { return false }
        var labels: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, "PageLabels", &labels) && labels != nil
    }
}
