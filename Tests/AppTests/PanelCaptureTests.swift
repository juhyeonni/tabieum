import AppKit
import NotesCore
import SwiftUI
import Testing

@testable import App
@testable import NotesCore

/// Run through `scripts/ui-capture.sh`; without `UI_CAPTURE_DIR` these do nothing.
@MainActor
struct PanelCaptureTests {
    @Test(.enabled(if: Capture.enabled))
    func captureAIPanel() throws {
        Capture.prepareApp()
        let panel = AIPanel(run: { _, _, _ in }, ask: { _ in }, accept: { _ in }, allow: {}, copy: {}, cancel: {})
        defer { panel.dismiss() }
        let phases: [(String, AIPanel.Phase)] = [
            ("input-selection", .input(hasSelection: true, chip: "Meeting notes", canAsk: true)),
            ("input", .input(hasSelection: false, chip: nil, canAsk: false)),
            ("input-ask", .input(hasSelection: false, chip: nil, canAsk: true)),
            ("streaming", .streaming("The meeting moved to")),
            ("done-note", .done("The meeting moved to Friday at 10:00.", .note)),
            ("done-reply", .done("It is on Friday at 10:00.", .reply)),
            ("answer", .answer("The meeting is on Friday at 10:00, in the blue room.")),
            ("failed", .failed("The provider did not answer.")),
            ("consent", .consent("api.example.com")),
            ("refused", .refused("The meeting moved to Friday at 10:00.")),
        ]
        for (name, phase) in phases {
            panel.render(phase)
            try Capture.captureLowered(panel, as: "ai-\(name)")
        }
    }

    @Test(.enabled(if: Capture.enabled))
    func captureSearchPanel() async throws {
        Capture.prepareApp()
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("ui-capture-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: index) }
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        try SearchIndex(url: index).upsert([
            IndexedNote(id: "1", title: "Weekly meeting", folder: "Work", modified: date, body: "Agenda for the weekly meeting: budget, hiring.", owner: "a"),
            IndexedNote(id: "2", title: "Meeting with the landlord", folder: "Home", modified: date, body: "Ask about the meeting room key.", owner: "a"),
            IndexedNote(id: "3", title: "Reading list", folder: "Notes", modified: date, body: "Books to read before the next meeting.", owner: "a"),
        ])
        let model = SearchModel(indexURL: index, embedder: { nil })
        let panel = SearchPanel(indexURL: index, embedder: { nil }).panel
        defer { panel.orderOut(nil) }
        panel.contentView = NSHostingView(rootView: SearchView(model: model, open: { _ in }, close: {}))
        try Capture.captureLowered(panel, as: "search-empty")

        model.query = "meeting"
        for _ in 0..<50 where model.hits.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!model.hits.isEmpty)
        try Capture.captureLowered(panel, as: "search-hits")
    }

    @Test(.enabled(if: Capture.enabled))
    func captureBacklinksPanel() throws {
        Capture.prepareApp()
        let backlinks = BacklinksPanel(indexURL: FileManager.default.temporaryDirectory.appendingPathComponent("none.sqlite"))
        let panel = backlinks.panel
        defer { panel.orderOut(nil) }
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        backlinks.show([], "No notes link here.")
        try Capture.captureLowered(panel, as: "backlinks-none")
        backlinks.show(
            [
                Backlink(id: "1", title: "Project plan", folder: "Work", modified: date),
                Backlink(id: "2", title: "Reading list", folder: "Notes", modified: date),
            ], "")
        try Capture.captureLowered(panel, as: "backlinks-rows")
    }

    @Test(.enabled(if: Capture.enabled))
    func captureToast() throws {
        Capture.prepareApp()
        Toast.show("Copied as Markdown")
        defer { Toast.panel.orderOut(nil) }
        try Capture.captureLowered(Toast.panel, as: "toast")
    }

    @Test(.enabled(if: Capture.enabled))
    func captureActionButton() throws {
        Capture.prepareApp()
        let suite = "ui-capture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = FakeTextFocusSource(frame: CGRect(x: 300, y: 200, width: 600, height: 400))
        let tracker = TextFocusTracker(source: source)
        let button = ActionButton(tracker: tracker, toggles: FeatureToggles(defaults: defaults), perform: { _ in })
        defer { button.panel.orderOut(nil) }
        try Capture.captureLowered(button.panel, as: "action-button")
    }
}
