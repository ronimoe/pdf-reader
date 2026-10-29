import ReaderCore
import SwiftUI

/// The Go to Page sheet (spec §5.2): one field that takes a page label the
/// document defines, or a page number.
@Observable
public final class GoToPageModel {
    public let numbering: PageNumbering
    public var input: String
    public private(set) var errorMessage: String?

    /// Called with the page index to go to; the sheet closes after.
    @ObservationIgnored public var onGo: (Int) -> Void
    @ObservationIgnored public var onCancel: () -> Void

    public init(
        numbering: PageNumbering,
        currentPageIndex: Int,
        onGo: @escaping (Int) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        self.numbering = numbering
        input = numbering.label(forPageAt: currentPageIndex)
        self.onGo = onGo
        self.onCancel = onCancel
    }

    public var prompt: String {
        numbering.definesLabels
            ? "Enter a page label, such as “\(numbering.label(forPageAt: 0))”, or a page number from 1 to \(numbering.pageCount)."
            : "Enter a page number from 1 to \(numbering.pageCount)."
    }

    /// Goes to the page, or explains why the input names no page and keeps
    /// the sheet up.
    public func submit() {
        switch numbering.pageIndex(for: input) {
        case .success(let index):
            errorMessage = nil
            onGo(index)
        case .failure(let error):
            errorMessage = numbering.message(for: error)
            AccessibilityNotification.Announcement(errorMessage ?? "").post()
        }
    }

    public func cancel() {
        onCancel()
    }
}

public struct GoToPageView: View {
    @Bindable private var model: GoToPageModel
    @FocusState private var fieldFocused: Bool

    public init(model: GoToPageModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page")
                .font(.headline)
            Text(model.prompt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Page", text: $model.input)
                .focused($fieldFocused)
                .onSubmit { model.submit() }
                .accessibilityLabel("Page")
                .accessibilityHint(model.prompt)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { fieldFocused = true }
    }
}
