import CoreGraphics
import Foundation

public enum VimCursorSetting: String, CaseIterable, Sendable {
    case modeBased
    case alwaysBar

    public var displayName: String {
        switch self {
        case .modeBased: "Mode-based"
        case .alwaysBar: "Always bar"
        }
    }
}

public enum VimCursorShape: Equatable, Sendable {
    case block, bar
}

public func vimCursorShape(mode: VimMode, setting: VimCursorSetting) -> VimCursorShape {
    guard setting == .modeBased, mode != .insert else { return .bar }
    return .block
}

/// The character under the cursor; a selection's cursor is its last character. An empty line or the end of the note gets a block half as wide as the line is tall.
public func vimCursorBlockRect(
    text: String, selection: NSRange,
    boundsFor: (NSRange) -> CGRect?, caretRect: () -> CGRect?
) -> CGRect? {
    let ns = text as NSString
    let at = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
    if at < ns.length {
        let range = ns.rangeOfComposedCharacterSequence(at: at)
        let isBreak = ns.substring(with: range).trimmingCharacters(in: .newlines).isEmpty
        if !isBreak, let rect = boundsFor(range), rect.size != .zero { return rect }
    }
    guard let line = caretRect(), line.height > 0 else { return nil }
    let afterCharacter = at > 0 && !ns.substring(with: ns.rangeOfComposedCharacterSequence(at: at - 1))
        .trimmingCharacters(in: .newlines).isEmpty
    return CGRect(x: afterCharacter ? line.maxX : line.minX, y: line.minY, width: line.height / 2, height: line.height)
}
