import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the empty state shows and does (spec §4.3): an Open Document action
/// and the recent files, nothing else.
@Observable
public final class EmptyStateModel {
    public struct RecentDocument: Identifiable, Hashable {
        public let url: URL
        public var id: URL { url }
        public var name: String { url.deletingPathExtension().lastPathComponent }
        public var location: String {
            url.deletingLastPathComponent().path(percentEncoded: false)
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }

        public init(url: URL) {
            self.url = url
        }
    }

    public var recents: [RecentDocument]
    /// True while a PDF is dragged over the window.
    public var isDropTargeted = false

    @ObservationIgnored public var onOpenDocument: () -> Void
    @ObservationIgnored public var onOpenURLs: ([URL]) -> Void

    public init(
        recents: [URL] = [],
        onOpenDocument: @escaping () -> Void = {},
        onOpenURLs: @escaping ([URL]) -> Void = { _ in }
    ) {
        self.recents = recents.map(RecentDocument.init)
        self.onOpenDocument = onOpenDocument
        self.onOpenURLs = onOpenURLs
    }

    public func setRecents(_ urls: [URL]) {
        recents = urls.map(RecentDocument.init)
    }
}

public struct EmptyStateView: View {
    @Bindable private var model: EmptyStateModel
    @State private var selection: URL?
    @FocusState private var listFocused: Bool

    public init(model: EmptyStateModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 20) {
            Button {
                model.onOpenDocument()
            } label: {
                Label("Open Document…", systemImage: "doc")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .help("Choose a PDF to open (⌘O)")

            if model.recents.isEmpty {
                Text("No Recent Documents")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                recentList
            }
        }
        .padding(24)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 300, idealHeight: 420)
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Documents")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            List(model.recents, selection: $selection) { recent in
                RecentRow(recent: recent)
                    .tag(recent.url)
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .focused($listFocused)
            // Return and double-click both open the selection.
            .contextMenu(forSelectionType: URL.self) { urls in
                Button("Open") { model.onOpenURLs(Array(urls)) }
            } primaryAction: { urls in
                model.onOpenURLs(Array(urls))
            }
            .accessibilityLabel("Recent Documents")
            .accessibilityHint("Press Return to open the selected document")
        }
        .onAppear {
            selection = model.recents.first?.url
            listFocused = true
        }
    }
}

private struct RecentRow: View {
    let recent: EmptyStateModel.RecentDocument

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: .pdf))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(recent.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recent.name), in \(recent.location)")
        .help(recent.url.path(percentEncoded: false))
    }
}
