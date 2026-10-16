import Combine
import Foundation

public final class FeatureToggles: ObservableObject {
    private let defaults: UserDefaults

    @Published public var vimEnabled: Bool { didSet { defaults.set(vimEnabled, forKey: "vimEnabled") } }
    @Published public var ragEnabled: Bool { didSet { defaults.set(ragEnabled, forKey: "ragEnabled") } }
    @Published public var aiEnabled: Bool { didSet { defaults.set(aiEnabled, forKey: "aiEnabled") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        vimEnabled = defaults.bool(forKey: "vimEnabled")
        ragEnabled = defaults.bool(forKey: "ragEnabled")
        aiEnabled = defaults.bool(forKey: "aiEnabled")
    }
}
