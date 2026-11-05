import Foundation
import NotesCore
import Testing

@testable import App

@MainActor
private final class CountingSource: TextFocusSource {
    let isTrusted = true
    let frontmostBundleID: String? = TextFocusTracker.notesBundleID
    let focusedRole: String? = TextFocusTracker.editorRole
    let textLength: Int? = 0
    let text: String? = ""
    let frame: CGRect? = nil
    private(set) var observers = 0
    func selectedRange() -> NSRange? { NSRange(location: 0, length: 0) }
    func setSelectedRange(_ range: NSRange) {}
    func bounds(for range: NSRange) -> CGRect? { nil }
    func startObserving(_ onChange: @escaping () -> Void) { observers += 1 }
    func stopObserving() { observers -= 1 }
}

@MainActor
struct FormatToolbarTests {
    @Test func observesSelectionOnlyWhileTheOptionIsOn() throws {
        let suite = "format-toolbar-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = CountingSource()
        let toggles = FeatureToggles(defaults: defaults)
        let toolbar = FormatToolbar(tracker: TextFocusTracker(source: source), toggles: toggles)
        #expect(source.observers == 0 && !toolbar.isObserving)
        toggles.formatToolbarEnabled = true
        #expect(source.observers == 1 && toolbar.isObserving)
        toggles.formatToolbarEnabled = false
        #expect(source.observers == 0 && !toolbar.isObserving)
    }
}
