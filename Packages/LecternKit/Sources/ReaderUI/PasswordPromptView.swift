import SwiftUI

/// The password sheet (B6). "Remember in Keychain" is off by default; the
/// owner of the model decides what a correct password is.
@Observable
public final class PasswordPromptModel {
    public enum Purpose: Equatable, Sendable {
        /// The document is locked and can't be shown without a password.
        case open
        /// The document is open but restricted; the owner password lifts the
        /// restrictions for this session.
        case removeRestrictions
    }

    public let documentName: String
    public let purpose: Purpose
    public var password = ""
    public var remember = false
    public private(set) var errorMessage: String?

    /// Returns true when the password was accepted.
    @ObservationIgnored public var onSubmit: (_ password: String, _ remember: Bool) -> Bool
    @ObservationIgnored public var onCancel: () -> Void

    public init(
        documentName: String,
        purpose: Purpose,
        onSubmit: @escaping (String, Bool) -> Bool = { _, _ in false },
        onCancel: @escaping () -> Void = {}
    ) {
        self.documentName = documentName
        self.purpose = purpose
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public var title: String {
        switch purpose {
        case .open: "“\(documentName)” is password protected"
        case .removeRestrictions: "Enter the owner password for “\(documentName)”"
        }
    }

    public var message: String {
        switch purpose {
        case .open: "Enter the document’s password to open it."
        case .removeRestrictions: "The owner password removes the document’s restrictions until you close it."
        }
    }

    public var submitTitle: String {
        switch purpose {
        case .open: "Open"
        case .removeRestrictions: "Unlock"
        }
    }

    public func submit() {
        guard !password.isEmpty else { return }
        if onSubmit(password, remember) {
            // Don't keep the password in memory longer than needed.
            password = ""
            errorMessage = nil
        } else {
            errorMessage = switch purpose {
            case .open: "That password is incorrect. Try again."
            case .removeRestrictions: "That isn’t the owner password. Try again."
            }
            password = ""
            AccessibilityNotification.Announcement(errorMessage ?? "").post()
        }
    }

    public func cancel() {
        onCancel()
    }
}

public struct PasswordPromptView: View {
    @Bindable private var model: PasswordPromptModel
    @FocusState private var passwordFocused: Bool

    public init(model: PasswordPromptModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.doc")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SecureField("Password", text: $model.password)
                .focused($passwordFocused)
                .onSubmit { model.submit() }
                .accessibilityLabel("Password")

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Toggle("Remember in Keychain", isOn: $model.remember)
                .help("Store this password in your login keychain so you aren’t asked again")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.submitTitle) { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { passwordFocused = true }
    }
}
