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
