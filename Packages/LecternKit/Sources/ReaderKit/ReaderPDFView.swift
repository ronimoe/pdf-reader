import AppKit
import PDFKit

/// The reading surface. Later milestones add link interception, anchors and
/// keyboard link focus here; this is the only type that subclasses PDFView.
public final class ReaderPDFView: PDFView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoScales = true
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
