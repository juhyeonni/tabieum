import AppKit
import Combine
import NotesCore

/// Turns a Markdown marker typed at the start of a line in Notes into the matching Notes style.
/// Observes Notes only while at least one shortcut is on.
@MainActor
final class MarkdownShortcuts {
    private let tracker: TextFocusTracker
    private let toggles: FeatureToggles
    private var subscription: Int?
    private var previous: TextSnapshot?
    private var togglesSink: AnyCancellable?

    init(tracker: TextFocusTracker, toggles: FeatureToggles) {
        self.tracker = tracker
        self.toggles = toggles
        togglesSink = toggles.$markdownStyles.sink { [weak self] styles in
            MainActor.assumeIsolated { self?.setObserving(!styles.isEmpty) }
        }
    }

    private func setObserving(_ on: Bool) {
        if on, subscription == nil {
            subscription = tracker.subscribe { [weak self] _ in self?.textChanged() }
        } else if !on, let subscription {
            tracker.unsubscribe(subscription)
            self.subscription = nil
            previous = nil
        }
    }

    private func textChanged() {
        let current = tracker.snapshot()
        defer { previous = current }
        guard let previous, let current,
              let match = markdownMatch(previous: previous, current: current, enabled: toggles.markdownStyles)
        else { return }
        NotesControl.apply(match.style.style, replacing: match.range, tracker: tracker)
    }
}
