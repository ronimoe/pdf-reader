import Foundation

/// Where a presentation is, and what each presentation command does to it. Pure, so the package
/// tests cover every key: the slide view and the presentation window only turn keys and clicks
/// into `Command`s and draw what this says.
public struct SlideNavigator: Equatable, Sendable {
    /// A blanked screen, as in Keynote and PowerPoint: black (B or .) or white (W or ,).
    public enum Blank: Equatable, Sendable {
        case black, white
    }

    public enum Command: Equatable, Sendable {
        case next, previous, first, last
        /// A digit typed towards a slide number.
        case digit(Int)
        /// Return: goes to the typed slide, or to the next one when nothing was typed.
        case confirm
        /// Delete: removes the last typed digit, or goes back a slide when nothing was typed.
        case deleteBackward
        case toggleBlack, toggleWhite
        /// Escape: clears a typed number; otherwise ends the presentation.
        case cancel
    }

    public enum Effect: Equatable, Sendable {
        /// The slide, the blanking or the typed number changed.
        case changed
        /// Nothing to do, such as going back from the first slide.
        case unchanged
        /// The typed number names no slide. It has been cleared.
        case noSuchSlide(String)
        /// The presentation should end.
        case end
    }

    /// The slide showing, a page index.
    public private(set) var index: Int
    public private(set) var pageCount: Int
    /// Set while the screen is blanked; the slide stays where it was.
    public private(set) var blank: Blank?
    /// The digits typed so far, waiting for Return.
    public private(set) var typed = ""
    /// The slides left by following links, most recent last, for a link's GoBack action.
    public private(set) var linkHistory: [Int] = []

    /// The longest slide number that can be typed.
    public static let maximumTypedDigits = 6
    static let linkHistoryLimit = 100

    public init(pageCount: Int, startingAt index: Int) {
        self.pageCount = max(0, pageCount)
        self.index = Self.clamp(index, toPageCount: pageCount)
    }

    /// Applies one command. A typed number goes through `numbering`, so it can be a page label
    /// the document defines (Beamer gives every overlay of a frame the frame's number), as in
    /// Go to Page, or else a page number.
    public mutating func perform(_ command: Command, numbering: PageNumbering) -> Effect {
        switch command {
        case let .digit(digit):
            guard (0...9).contains(digit), typed.count < Self.maximumTypedDigits else { return .unchanged }
            typed += String(digit)
            return .changed
        case .confirm:
            guard !typed.isEmpty else { return move(to: index + 1) }
            let input = typed
            typed = ""
            switch numbering.pageIndex(for: input) {
            case let .success(target) where target < pageCount:
                blank = nil
                index = target
                return .changed
            default:
                return .noSuchSlide(input)
            }
        case .deleteBackward:
            guard typed.isEmpty else {
                typed.removeLast()
                return .changed
            }
            return move(to: index - 1)
        case .cancel:
            guard typed.isEmpty else {
                typed = ""
                return .changed
            }
            return .end
        case .toggleBlack:
            blank = blank == .black ? nil : .black
            return .changed
        case .toggleWhite:
            blank = blank == .white ? nil : .white
            return .changed
        case .next: return move(to: index + 1)
        case .previous: return move(to: index - 1)
        case .first: return move(to: 0)
        case .last: return move(to: pageCount - 1)
        }
    }

    /// Moves to `target`, clamped to the document: there is no wrapping past either end. On a
    /// blanked screen the first move only brings the slide back, so the audience sees the slide
    /// they left before the break.
    private mutating func move(to target: Int) -> Effect {
        let hadTyped = !typed.isEmpty
        typed = ""
        if blank != nil {
            blank = nil
            return .changed
        }
        let clamped = Self.clamp(target, toPageCount: pageCount)
        guard clamped != index else { return hadTyped ? .changed : .unchanged }
        index = clamped
        return .changed
    }

    /// Follows a link on a slide to the slide at `target`, remembering where it was for GoBack.
    public mutating func follow(to target: Int) -> Effect {
        let clamped = Self.clamp(target, toPageCount: pageCount)
        blank = nil
        typed = ""
        guard clamped != index else { return .changed }
        linkHistory.append(index)
        if linkHistory.count > Self.linkHistoryLimit { linkHistory.removeFirst() }
        index = clamped
        return .changed
    }

    /// A link's GoBack action: the slide the last followed link left.
    public mutating func goBack() -> Effect {
        guard let previous = linkHistory.popLast() else { return .unchanged }
        blank = nil
        typed = ""
        index = Self.clamp(previous, toPageCount: pageCount)
        return .changed
    }

    /// The document reloaded with `count` pages: stay on the same slide if it still exists.
    public mutating func setPageCount(_ count: Int) {
        pageCount = max(0, count)
        index = Self.clamp(index, toPageCount: pageCount)
        linkHistory = linkHistory.map { Self.clamp($0, toPageCount: pageCount) }
    }

    static func clamp(_ index: Int, toPageCount count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }
}
