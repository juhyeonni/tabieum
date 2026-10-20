import CoreGraphics

/// The buttons of the toolbar shown over a selection, in order.
public enum FormatTool: CaseIterable, Sendable {
    case bold, italic, underline, strikethrough, title, bulletedList, checklist

    /// The Notes Format menu item's key equivalent, as `NotesStyle.keyEquivalent` writes it.
    public var keyEquivalent: (char: String, modifiers: Int) {
        switch self {
        case .bold: ("B", 0)
        case .italic: ("I", 0)
        case .underline: ("U", 0)
        case .strikethrough: ("X", 1)
        case .title: NotesStyle.title.keyEquivalent
        case .bulletedList: NotesStyle.bulletedList.keyEquivalent
        case .checklist: NotesStyle.checklist.keyEquivalent
        }
    }

    public var displayName: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .title: "Title"
        case .bulletedList: "Bulleted list"
        case .checklist: "Checklist"
        }
    }

    public var symbolName: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .title: "textformat.size.larger"
        case .bulletedList: "list.bullet"
        case .checklist: "checklist"
        }
    }
}

public func shouldShowFormatToolbar(selectionLength: Int?, isFocused: Bool, enabled: Bool) -> Bool {
    enabled && isFocused && (selectionLength ?? 0) > 0
}

/// The frame for the toolbar of `size` just above `selection`, or below it when there is no room above, then clamped into `visible`.
/// All rects are in AppKit coordinates.
public func formatToolbarFrame(selection: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = 6) -> CGRect {
    var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.maxY + gap)
    if origin.y + size.height > visible.maxY { origin.y = selection.minY - gap - size.height }
    origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
    origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
    return CGRect(origin: origin, size: size)
}
