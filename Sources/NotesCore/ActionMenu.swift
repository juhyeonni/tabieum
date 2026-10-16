import CoreGraphics

public enum ActionMenuItem: CaseIterable, Equatable, Sendable {
    case copyMarkdown, copyDeeplink, backlinks, askNotes, settings

    public var title: String {
        switch self {
        case .copyMarkdown: "Copy as Markdown"
        case .copyDeeplink: "Copy Deeplink"
        case .backlinks: "Backlinks"
        case .askNotes: "Ask my notes…"
        case .settings: "Settings…"
        }
    }
}

public struct ActionMenuModel: Equatable, Sendable {
    public let header: String
    public let items: [ActionMenuItem]

    /// `title` is nil when no single note can be told apart.
    public init(title: String?, ambiguous: Bool) {
        let name = title.map { $0.isEmpty ? "Untitled" : $0 } ?? "No note open"
        header = ambiguous ? "\(name) (another note has this title)" : name
        items = ActionMenuItem.allCases
    }
}

/// The button's rect at the bottom-right of the visible editor `frame`, in the same coordinate space as `frame`.
public func actionButtonRect(in frame: CGRect, size: CGSize, inset: CGFloat = 8) -> CGRect {
    CGRect(x: frame.maxX - inset - size.width, y: frame.maxY - inset - size.height, width: size.width, height: size.height)
}
