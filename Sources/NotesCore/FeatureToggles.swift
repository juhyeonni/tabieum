import Combine
import CoreGraphics
import Foundation

public final class FeatureToggles: ObservableObject {
    private let defaults: UserDefaults

    @Published public var vimEnabled: Bool { didSet { defaults.set(vimEnabled, forKey: "vimEnabled") } }
    @Published public var vimJKEnabled: Bool { didSet { defaults.set(vimJKEnabled, forKey: "vimJKEnabled") } }
    @Published public var ragEnabled: Bool { didSet { defaults.set(ragEnabled, forKey: "ragEnabled") } }
    @Published public var aiEnabled: Bool { didSet { defaults.set(aiEnabled, forKey: "aiEnabled") } }
    @Published public var aiShortcut: HotKey {
        didSet {
            defaults.set(Int(aiShortcut.keyCode), forKey: "aiShortcutKeyCode")
            defaults.set(Int(aiShortcut.modifiers.rawValue), forKey: "aiShortcutModifiers")
            defaults.set(aiShortcut.key, forKey: "aiShortcutKey")
        }
    }
    /// Markdown shortcuts that are on. Each is on until turned off.
    @Published public var markdownStyles: Set<MarkdownStyle> {
        didSet {
            for style in MarkdownStyle.allCases { defaults.set(markdownStyles.contains(style), forKey: Self.key(style)) }
        }
    }

    /// The folder, in every account, whose notes the `/` panel lists as templates.
    @Published public var templateFolder: String { didSet { defaults.set(templateFolder, forKey: "templateFolder") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        templateFolder = defaults.string(forKey: "templateFolder") ?? "Templates"
        vimEnabled = defaults.bool(forKey: "vimEnabled")
        vimJKEnabled = defaults.bool(forKey: "vimJKEnabled")
        ragEnabled = defaults.bool(forKey: "ragEnabled")
        aiEnabled = defaults.bool(forKey: "aiEnabled")
        let stored = HotKey(keyCode: UInt16(defaults.integer(forKey: "aiShortcutKeyCode")),
                            modifiers: CGEventFlags(rawValue: UInt64(defaults.integer(forKey: "aiShortcutModifiers"))),
                            key: defaults.string(forKey: "aiShortcutKey") ?? "")
        aiShortcut = defaults.object(forKey: "aiShortcutKeyCode") != nil && stored.isValid ? stored : .aiDefault
        markdownStyles = Set(MarkdownStyle.allCases.filter { defaults.object(forKey: Self.key($0)) as? Bool ?? true })
    }

    private static func key(_ style: MarkdownStyle) -> String { "markdown.\(style.rawValue)" }
}
