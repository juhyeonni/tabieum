import Foundation

/// US-ANSI virtual keycodes to (unshifted, shifted) characters.
private let usANSI: [Int: (Character, Character)] = [
    0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"), 5: ("g", "G"),
    6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"), 12: ("q", "Q"),
    13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"), 16: ("y", "Y"), 17: ("t", "T"),
    18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 22: ("6", "^"), 23: ("5", "%"),
    24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"), 28: ("8", "*"), 29: ("0", ")"),
    30: ("]", "}"), 31: ("o", "O"), 32: ("u", "U"), 33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"),
    36: ("\n", "\n"), 37: ("l", "L"), 38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"),
    42: ("\\", "|"), 43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"), 47: (".", ">"),
    48: ("\t", "\t"), 49: (" ", " "), 50: ("`", "~"),
]

private let escapeKeyCode = 53
private let leftBracketKeyCode = 33

/// Turns a key-down into an engine key. Normal and Visual read the keycode through a fixed US-ANSI table,
/// whatever the input source; Insert takes the event's own characters so IME input stays untouched.
/// Returns nil for keys the engine has no use for (arrows, function keys), which then pass through.
public func vimKey(
    keyCode: Int, shift: Bool, control: Bool, command: Bool, characters: String, mode: VimMode
) -> VimKey? {
    if !command && (keyCode == escapeKeyCode || (control && keyCode == leftBracketKeyCode)) {
        return .escape
    }
    let character: Character?
    if keyCode == escapeKeyCode {
        character = "\u{1B}"
    } else if mode == .search, keyCode == 36 {
        character = "\n"
    } else if mode == .search, keyCode == 51 {
        character = "\u{7F}"
    } else if mode == .insert || mode == .search {
        character = characters.first
    } else {
        character = usANSI[keyCode].map { shift ? $0.1 : $0.0 }
    }
    guard let character else { return nil }
    return VimKey(character, control: control, command: command)
}

/// Where Vim cannot trust the AX ranges (tables, attachments), a left, down, up or right motion is the arrow key instead.
public func fallbackArrowKeyCode(for command: VimCommand) -> Int? {
    guard case .motion(let motion) = command else { return nil }
    return switch motion {
    case .left: 123
    case .right: 124
    case .down: 125
    case .up: 126
    default: nil
    }
}
