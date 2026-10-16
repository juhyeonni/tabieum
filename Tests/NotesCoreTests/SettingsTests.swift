import Foundation
import Testing
@testable import NotesCore

private func freshSuite() -> UserDefaults {
    let name = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func togglesAreOffByDefaultAndPersist() {
    let defaults = freshSuite()
    let toggles = FeatureToggles(defaults: defaults)
    #expect(!toggles.vimEnabled && !toggles.vimJKEnabled && !toggles.ragEnabled && !toggles.aiEnabled)
    toggles.vimEnabled = true
    toggles.vimJKEnabled = true
    toggles.aiEnabled = true
    let reloaded = FeatureToggles(defaults: defaults)
    #expect(reloaded.vimEnabled && reloaded.vimJKEnabled && !reloaded.ragEnabled && reloaded.aiEnabled)
}

@Test func automationStatusMapping() {
    #expect(PermissionState(automationStatus: 0) == .granted)
    #expect(PermissionState(automationStatus: -1743) == .notGranted)
    #expect(PermissionState(automationStatus: -1744) == .notGranted)
    #expect(PermissionState(automationStatus: -600) == .notesNotRunning)
}

@Test func fullDiskAccessProbe() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(PermissionState(fullDiskAccessProbe: url.path) == .granted)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    #expect(PermissionState(fullDiskAccessProbe: url.path) == .notGranted)
}

@Test func settingsURLs() {
    let base = "x-apple.systempreferences:com.apple.preference.security?"
    #expect(Permission.accessibility.settingsURL.absoluteString == base + "Privacy_Accessibility")
    #expect(Permission.fullDiskAccess.settingsURL.absoluteString == base + "Privacy_AllFiles")
    #expect(Permission.automation.settingsURL.absoluteString == base + "Privacy_Automation")
}
