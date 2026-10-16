import Combine
import Foundation

public final class FeatureToggles: ObservableObject {
    private let defaults: UserDefaults

    @Published public var vimEnabled: Bool { didSet { defaults.set(vimEnabled, forKey: "vimEnabled") } }
    @Published public var ragEnabled: Bool { didSet { defaults.set(ragEnabled, forKey: "ragEnabled") } }
    @Published public var aiEnabled: Bool { didSet { defaults.set(aiEnabled, forKey: "aiEnabled") } }
    /// Markdown shortcuts that are on. Each is on until turned off.
    @Published public var markdownStyles: Set<MarkdownStyle> {
        didSet {
            for style in MarkdownStyle.allCases { defaults.set(markdownStyles.contains(style), forKey: Self.key(style)) }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        vimEnabled = defaults.bool(forKey: "vimEnabled")
        ragEnabled = defaults.bool(forKey: "ragEnabled")
        aiEnabled = defaults.bool(forKey: "aiEnabled")
        markdownStyles = Set(MarkdownStyle.allCases.filter { defaults.object(forKey: Self.key($0)) as? Bool ?? true })
    }

    private static func key(_ style: MarkdownStyle) -> String { "markdown.\(style.rawValue)" }
}
