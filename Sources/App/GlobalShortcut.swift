import AppKit
import Carbon.HIToolbox
import NotesCore
import SwiftUI

/// Registers one global shortcut with Carbon `RegisterEventHotKey`: it needs no permission and consumes the key.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private let id: UInt32

    init(id: UInt32, onPress: @escaping () -> Void) {
        self.id = id
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { event, _, userData in
            guard let userData, let event else { return noErr }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in hotKey.onPress() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E58_4B59), id: id)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.rawValue, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// Owns one global shortcut: registers it, saves it, and reports a registration failure.
@MainActor
final class ShortcutController: ObservableObject {
    @Published private(set) var shortcut: Shortcut
    @Published private(set) var error: String?
    let title: String
    private let toggles: FeatureToggles
    private let keyPath: ReferenceWritableKeyPath<FeatureToggles, Shortcut>
    private let hotKey: HotKey

    init(toggles: FeatureToggles, title: String, id: UInt32, keyPath: ReferenceWritableKeyPath<FeatureToggles, Shortcut>,
         onPress: @escaping () -> Void) {
        self.toggles = toggles
        self.title = title
        self.keyPath = keyPath
        shortcut = toggles[keyPath: keyPath]
        hotKey = HotKey(id: id, onPress: onPress)
        error = hotKey.register(shortcut) ? nil : Self.takenMessage
    }

    private static let takenMessage = "That shortcut is already taken by another app."

    func set(_ new: Shortcut) {
        guard new.isValid else {
            error = "Use ⌘ or ⌃ with a letter, digit or Space."
            return
        }
        if hotKey.register(new) {
            toggles[keyPath: keyPath] = new
            shortcut = new
            error = nil
        } else {
            _ = hotKey.register(shortcut)
            error = Self.takenMessage
        }
    }
}

struct ShortcutRecorder: View {
    @ObservedObject var controller: ShortcutController
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(controller.title)
                Button(monitor == nil ? controller.shortcut.display : "Type a shortcut…", action: toggleRecording)
            }
            if let error = controller.error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if monitor != nil { return stopRecording() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != UInt16(kVK_Escape) { controller.set(Self.shortcut(from: event)) }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func shortcut(from event: NSEvent) -> Shortcut {
        let flags = event.modifierFlags
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
}
