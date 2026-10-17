import Combine
import CoreGraphics
import Foundation

public final class FeatureToggles: ObservableObject {
    private let defaults: UserDefaults

    @Published public var vimEnabled: Bool { didSet { defaults.set(vimEnabled, forKey: "vimEnabled") } }
    @Published public var vimJKEnabled: Bool { didSet { defaults.set(vimJKEnabled, forKey: "vimJKEnabled") } }
    @Published public var vimCursorShape: VimCursorSetting { didSet { defaults.set(vimCursorShape.rawValue, forKey: "vimCursorShape") } }
    @Published public var ragEnabled: Bool { didSet { defaults.set(ragEnabled, forKey: "ragEnabled") } }
    /// Whether the search panel also searches by meaning; it needs semantic search (RAG) to be on.
    @Published public var semanticPanelSearch: Bool { didSet { defaults.set(semanticPanelSearch, forKey: "semanticPanelSearch") } }
    @Published public var embeddingModel: EmbeddingModel { didSet { defaults.set(embeddingModel.rawValue, forKey: EmbeddingModel.defaultsKey) } }
    @Published public var mcpEnabled: Bool { didSet { defaults.set(mcpEnabled, forKey: "mcpEnabled") } }
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

    /// The global shortcut that opens the search panel.
    public var searchShortcut: Shortcut {
        get { shortcut("searchShortcut", fallback: .default) }
        set { setShortcut("searchShortcut", newValue) }
    }

    public var copyMarkdownShortcut: Shortcut {
        get { shortcut("copyMarkdownShortcut", fallback: .copyMarkdown) }
        set { setShortcut("copyMarkdownShortcut", newValue) }
    }

    public var copyLinkShortcut: Shortcut {
        get { shortcut("copyLinkShortcut", fallback: .copyLink) }
        set { setShortcut("copyLinkShortcut", newValue) }
    }

    private func shortcut(_ name: String, fallback: Shortcut) -> Shortcut {
        guard let code = defaults.object(forKey: "\(name).keyCode") as? Int,
              let flags = defaults.object(forKey: "\(name).modifiers") as? Int
        else { return fallback }
        let shortcut = Shortcut(keyCode: UInt32(code), modifiers: .init(rawValue: UInt32(flags)))
        return shortcut.isValid ? shortcut : fallback
    }

    private func setShortcut(_ name: String, _ value: Shortcut) {
        defaults.set(Int(value.keyCode), forKey: "\(name).keyCode")
        defaults.set(Int(value.modifiers.rawValue), forKey: "\(name).modifiers")
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        templateFolder = defaults.string(forKey: "templateFolder") ?? "Templates"
        vimEnabled = defaults.bool(forKey: "vimEnabled")
        vimJKEnabled = defaults.bool(forKey: "vimJKEnabled")
        vimCursorShape = defaults.string(forKey: "vimCursorShape").flatMap(VimCursorSetting.init(rawValue:)) ?? .modeBased
        ragEnabled = defaults.bool(forKey: "ragEnabled")
        semanticPanelSearch = defaults.bool(forKey: "semanticPanelSearch")
        embeddingModel = EmbeddingModel(defaults: defaults)
        mcpEnabled = defaults.bool(forKey: "mcpEnabled")
        aiEnabled = defaults.bool(forKey: "aiEnabled")
        let stored = HotKey(keyCode: UInt16(defaults.integer(forKey: "aiShortcutKeyCode")),
                            modifiers: CGEventFlags(rawValue: UInt64(defaults.integer(forKey: "aiShortcutModifiers"))),
                            key: defaults.string(forKey: "aiShortcutKey") ?? "")
        aiShortcut = defaults.object(forKey: "aiShortcutKeyCode") != nil && stored.isValid ? stored : .aiDefault
        markdownStyles = Set(MarkdownStyle.allCases.filter { defaults.object(forKey: Self.key($0)) as? Bool ?? true })
    }

    private static func key(_ style: MarkdownStyle) -> String { "markdown.\(style.rawValue)" }
}
