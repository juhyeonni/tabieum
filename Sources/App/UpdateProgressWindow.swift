import AppKit
import NotesCore

@MainActor
final class UpdateProgressWindow {
    var onCancel: () -> Void = {}
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 210), styleMask: [.titled], backing: .buffered, defer: false)
    private let steps = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)

    init() {
        window.title = "Updating"
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        cancel.target = self
        cancel.action = #selector(cancelled)
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [steps, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        window.contentView = stack
        window.isReleasedWhenClosed = false
    }

    func show(_ step: UpdateProgress.Step, _ fraction: Double) {
        let marks: [UpdateProgress.Mark: String] = [.done: "✓", .current: "●", .todo: "○"]
        steps.stringValue = UpdateProgress.lines(step: step, fraction: fraction)
            .map { "\(marks[$0.mark] ?? "")  \($0.text)" }.joined(separator: "\n")
        bar.doubleValue = (Double(step.rawValue) + (step == .downloading ? fraction : 0)) / 5
        if !window.isVisible {
            NSApp.activate()
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func lockCancel() { cancel.isEnabled = false }

    func close() { window.close() }

    @objc private func cancelled() { onCancel() }
}
