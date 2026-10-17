import AppKit
import ApplicationServices
import CoreServices
import NotesCore

@MainActor
final class PermissionStatus: ObservableObject {
    @Published private(set) var states: [Permission: PermissionState] = [:]
    private var timer: Timer?
    private var refreshing = false
    private var polling = false
    private var timerInterval: TimeInterval = 0

    var allGranted: Bool { Permission.allCases.allSatisfy { states[$0] == .granted } }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        states[.accessibility] = AXIsProcessTrusted() ? .granted : .notGranted
        states[.fullDiskAccess] = PermissionState(fullDiskAccessProbe: NotesDatabase.path)
        states[.automation] = await Task.detached { PermissionState(automationStatus: automationStatus(ask: false)) }.value
        schedule()
    }

    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSWorkspace.shared.open(permission.settingsURL)
        case .fullDiskAccess:
            NSWorkspace.shared.open(permission.settingsURL)
        case .automation:
            Task {
                let state = await Task.detached { PermissionState(automationStatus: automationStatus(ask: true)) }.value
                states[.automation] = state
                if state != .granted { NSWorkspace.shared.open(permission.settingsURL) }
            }
        }
    }

    func setPolling(_ on: Bool) {
        polling = on
        schedule()
    }

    private func schedule() {
        let interval = polling ? permissionPollInterval(allGranted: allGranted) : 0
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timer = nil
        timerInterval = interval
        guard polling else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
}

private func automationStatus(ask: Bool) -> Int32 {
    var target = AEAddressDesc()
    let bundleID = "com.apple.Notes"
    let created = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
    guard created == noErr else { return Int32(created) }
    defer { AEDisposeDesc(&target) }
    return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
}
