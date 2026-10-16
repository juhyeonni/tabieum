import Foundation

/// A global keyboard shortcut: a virtual key code plus Carbon-valued modifier flags.
public struct Shortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)
    }

    public static let `default` = Shortcut(keyCode: 45, modifiers: [.control, .option, .command])

    public static let copyMarkdown = Shortcut(keyCode: 46, modifiers: [.control, .option, .command])
    public static let copyLink = Shortcut(keyCode: 37, modifiers: [.control, .option, .command])

    private static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: "Space",
    ]

    public let keyCode: UInt32
    public let modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Since macOS 15, shortcuts without ⌘ or ⌃ fail to register. Only keys that have a name can be shown.
    public var isValid: Bool {
        !modifiers.isDisjoint(with: [.command, .control]) && Self.keyNames[keyCode] != nil
    }

    public var display: String {
        let symbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + (Self.keyNames[keyCode] ?? "?")
    }
}
