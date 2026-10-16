import Combine
import Foundation

public final class FeatureToggles: ObservableObject {
    private let defaults: UserDefaults

    @Published public var vimEnabled: Bool { didSet { defaults.set(vimEnabled, forKey: "vimEnabled") } }
    @Published public var vimJKEnabled: Bool { didSet { defaults.set(vimJKEnabled, forKey: "vimJKEnabled") } }
    @Published public var ragEnabled: Bool { didSet { defaults.set(ragEnabled, forKey: "ragEnabled") } }
    @Published public var mcpEnabled: Bool { didSet { defaults.set(mcpEnabled, forKey: "mcpEnabled") } }
    @Published public var aiEnabled: Bool { didSet { defaults.set(aiEnabled, forKey: "aiEnabled") } }
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
        mcpEnabled = defaults.bool(forKey: "mcpEnabled")
        aiEnabled = defaults.bool(forKey: "aiEnabled")
        markdownStyles = Set(MarkdownStyle.allCases.filter { defaults.object(forKey: Self.key($0)) as? Bool ?? true })
    }

    private static func key(_ style: MarkdownStyle) -> String { "markdown.\(style.rawValue)" }
}
