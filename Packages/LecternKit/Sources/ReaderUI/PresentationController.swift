import AppKit
import PDFKit
import ReaderCore
import ReaderKit

/// Puts a presentation on screen. The app uses a borderless window over a whole display; tests
/// host the controller's view in an invisible window instead. The presenter calls `didBegin()`
/// once the slides show and `didEnd()` once they have gone, however the presentation ended.
@MainActor
public protocol PresentationPresenting: AnyObject {
    /// Shows `controller` over `screen`, or the main screen when nil. Ends any presentation
    /// showing already: there is one at a time.
    func present(_ controller: PresentationController, on screen: NSScreen?)
    func dismiss(_ controller: PresentationController)
}

/// Puts nothing on screen. The app uses it while hosting tests, so a test that forgets its own
/// presenter can't cover the display.
public final class HeadlessPresentationPresenter: PresentationPresenting {
    public private(set) var current: PresentationController?

    public init() {}

    public func present(_ controller: PresentationController, on screen: NSScreen?) {
        if let current { dismiss(current) }
        current = controller
        controller.didBegin()
    }

    public func dismiss(_ controller: PresentationController) {
        guard controller === current else { return }
        current = nil
        controller.didEnd()
    }
}

/// A presentation (View ▸ Start Presentation, ⌥⌘P): one slide at a time over a whole display,
/// on black, from the reader's own `PDFDocument`. It has its own view, so the reader window,
/// its panes, their settings and their history don't change while it shows; when it ends, the
/// window moves the reader to the last slide shown.
///
/// Keys follow Keynote, PowerPoint and presentation remotes: → ↓ Space Page Down Return N for
/// the next slide; ← ↑ ⇧Space Page Up Delete P for the previous one; Home and End; a number and
/// Return to go to that slide; B or . for a black screen and W or , for a white one; Escape to
/// end. A click goes to the next slide, or follows the link under it.
public final class PresentationController: NSViewController {
    public let slideView = SlideView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    /// Brief notices along the bottom: how to end, the typed slide number, why a link wasn't
    /// followed.
    public let notice = NoticeView()
    public private(set) var navigator: SlideNavigator
    private var numbering: PageNumbering
    /// The notice is showing the number being typed, rather than a message.
    private var noticeShowsTypedNumber = false
    private var pointerTimer: Timer?

    /// Links that leave the document, or are blocked (A4), for the window to handle.
    public var onExternalLink: ((LinkTarget) -> Void)?
    /// Asks whoever started the presentation to end it.
    public var onDismissRequest: (() -> Void)?
    /// Called once when the presentation has ended, with the index of the last slide shown.
    public var onEnd: ((Int) -> Void)?
    public private(set) var hasBegun = false
    public private(set) var hasEnded = false

    /// How long the pointer stays after it stops moving.
    public static var pointerHideDelay: TimeInterval = 2
    /// Hides the pointer until the mouse moves (true), or shows it again (false). Tests replace
    /// it, so a test run never hides the real pointer.
    public static var setPointerHidden: (Bool) -> Void = { NSCursor.setHiddenUntilMouseMoves($0) }

    /// - Parameters:
    ///   - document: the reader's document, shared.
    ///   - index: the slide to start on.
    ///   - numbering: page labels, so a typed number can name a slide as its footer does.
    ///   - title: the document's name, for the window and VoiceOver.
    public init(document: PDFDocument, startingAt index: Int, numbering: PageNumbering, title: String) {
        navigator = SlideNavigator(pageCount: document.pageCount, startingAt: index)
        self.numbering = numbering
        super.init(nibName: nil, bundle: nil)
        self.title = "\(title) — Presentation"
        slideView.document = document
        slideView.pageIndex = navigator.index
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let root = NSView(frame: slideView.frame)
        slideView.onClick = { [weak self] in self?.perform(.next) }
        slideView.onActivateLink = { [weak self] target in self?.follow(target) }
        slideView.onPointerMoved = { [weak self] in self?.pointerDidMove() }
        slideView.setAccessibilityHelp("Right arrow for the next slide, left arrow for the previous one, Escape to end the presentation.")
        root.addSubview(slideView)
        root.pinEdges(of: slideView)
        notice.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
            notice.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        view = root
        updateSlideDescription()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(slideView)
    }

    /// The slide showing, a page index.
    public var currentIndex: Int { navigator.index }

    // MARK: Beginning and ending

    /// Called by the presenter once the slides show.
    public func didBegin() {
        guard !hasBegun else { return }
        hasBegun = true
        notice.show("Presenting. Press Escape to end.", duration: 2)
        Self.setPointerHidden(true)
    }

    /// Ends the presentation: Escape, ⌘., ⌘W or the menu's Stop Presentation.
    public func end() {
        guard !hasEnded else { return }
        onDismissRequest?()
    }

    /// Called by the presenter once the slides have gone.
    public func didEnd() {
        guard !hasEnded else { return }
        hasEnded = true
        pointerTimer?.invalidate()
        pointerTimer = nil
        notice.hide()
        Self.setPointerHidden(false)
        onEnd?(navigator.index)
    }

    /// ⌘. (and Escape, if it arrives as an action rather than a key).
    public override func cancelOperation(_ sender: Any?) {
        end()
    }

    /// View ▸ Stop Presentation: the menu item that starts a presentation from a reader window
    /// ends it from here.
    @objc public func togglePresentation(_ sender: Any?) {
        end()
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        // Keys that aren't presentation keys are swallowed: a beep would reach the audience.
        guard let command = Self.command(for: event) else { return }
        perform(command)
    }

    /// The presentation command for a key, or nil. Keys with ⌘, ⌥ or ⌃ are left to the menus.
    public static func command(for event: NSEvent) -> SlideNavigator.Command? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isSubset(of: .shift) else { return nil }
        switch event.keyCode {
        case 124, 125, 121: return .next // → ↓ Page Down
        case 123, 126, 116: return .previous // ← ↑ Page Up
        case 49: return modifiers.contains(.shift) ? .previous : .next // Space, ⇧Space
        case 36, 76: return .confirm // Return, keypad Enter
        case 51: return .deleteBackward // Delete
        case 115: return .first // Home
        case 119: return .last // End
        case 53: return .cancel // Escape
        default: break
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1,
              let character = characters.first
        else { return nil }
        if character.isASCII, let digit = character.wholeNumberValue { return .digit(digit) }
        switch character {
        case "n": return .next
        case "p": return .previous
        case "b", ".": return .toggleBlack
        case "w", ",": return .toggleWhite
        default: return nil
        }
    }

    /// Applies a command and shows the result.
    @discardableResult
    public func perform(_ command: SlideNavigator.Command) -> SlideNavigator.Effect {
        let effect = navigator.perform(command, numbering: numbering)
        apply(effect)
        if command != .cancel { Self.setPointerHidden(true) }
        return effect
    }

    private func apply(_ effect: SlideNavigator.Effect) {
        switch effect {
        case .end:
            end()
        case let .noSuchSlide(typed):
            showSlide()
            noticeShowsTypedNumber = false
            notice.show("There’s no slide \(typed).", duration: 1.5)
        case .changed, .unchanged:
            showSlide()
        }
    }

    /// Draws what the navigator says, and shows the number being typed while there is one.
    private func showSlide() {
        let moved = slideView.pageIndex != navigator.index
        slideView.pageIndex = navigator.index
        slideView.blank = navigator.blank
        if !navigator.typed.isEmpty {
            noticeShowsTypedNumber = true
            notice.show("Go to slide \(navigator.typed)", duration: nil)
        } else if noticeShowsTypedNumber {
            noticeShowsTypedNumber = false
            notice.hide()
        }
        updateSlideDescription()
        if moved, hasBegun {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: slideView.accessibilityLabel() ?? "", .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }
    }

    private func updateSlideDescription() {
        let label: String
        switch navigator.blank {
        case .black: label = "Black screen"
        case .white: label = "White screen"
        case nil: label = Self.description(ofSlideAt: navigator.index, numbering: numbering, count: navigator.pageCount)
        }
        slideView.setAccessibilityLabel(label)
    }

    /// "Slide 4 of 20", or "Slide 3 (4 of 20)" when the document's own label differs.
    public static func description(ofSlideAt index: Int, numbering: PageNumbering, count: Int) -> String {
        let number = String(index + 1)
        let label = numbering.label(forPageAt: index)
        return label == number ? "Slide \(number) of \(count)" : "Slide \(label) (\(number) of \(count))"
    }

    // MARK: Links

    /// A link on a slide: one inside the document moves the presentation, with GoBack to
    /// return; page actions move it too; anything else goes to the window, under A4's policy.
    public func follow(_ target: LinkTarget) {
        switch target {
        case let .destination(destination):
            guard let page = destination.page, let document = slideView.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            apply(navigator.follow(to: index))
        case let .named(name):
            switch name {
            case .nextPage: perform(.next)
            case .previousPage: perform(.previous)
            case .firstPage: perform(.first)
            case .lastPage: perform(.last)
            case .goBack: apply(navigator.goBack())
            // GoForward, Print, Find, Zoom…: nothing, and no beep in front of an audience.
            default: break
            }
        case .web, .otherScheme, .blocked:
            onExternalLink?(target)
        }
    }

    // MARK: Changes in the reader

    /// The document reloaded after a change on disk (B7): the slides follow it, on the same slide
    /// where it still exists.
    public func documentDidReload(_ document: PDFDocument, numbering: PageNumbering) {
        self.numbering = numbering
        navigator.setPageCount(document.pageCount)
        slideView.document = document
        showSlide()
    }

    /// The pages' rotation or annotations changed in the reader.
    public func refresh() {
        slideView.refresh()
    }

    // MARK: Pointer

    /// The pointer shows while it moves and hides once it rests, so it never sits on a slide.
    private func pointerDidMove() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pointerHideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hasEnded else { return }
                self.pointerTimer = nil
                Self.setPointerHidden(true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }
}

extension PresentationController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePresentation(_:)) {
            menuItem.title = "Stop Presentation"
        }
        return true
    }
}
