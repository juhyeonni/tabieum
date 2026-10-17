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

@Test func embeddingModelDefaultsToAppleAndPersists() {
    let defaults = freshSuite()
    let toggles = FeatureToggles(defaults: defaults, e5Available: true)
    #expect(toggles.embeddingModel == .apple)
    toggles.embeddingModel = .e5Small
    #expect(FeatureToggles(defaults: defaults, e5Available: true).embeddingModel == .e5Small)
    #expect(FeatureToggles(defaults: defaults, e5Available: false).embeddingModel == .apple)
    defaults.set("removed-model", forKey: EmbeddingModel.defaultsKey)
    #expect(FeatureToggles(defaults: defaults, e5Available: true).embeddingModel == .apple)
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

@Test func shortcutValidation() {
    let n: UInt32 = 45
    #expect(Shortcut(keyCode: n, modifiers: [.command]).isValid)
    #expect(Shortcut(keyCode: n, modifiers: [.control, .shift]).isValid)
    #expect(!Shortcut(keyCode: n, modifiers: [.option]).isValid)
    #expect(!Shortcut(keyCode: n, modifiers: [.shift, .option]).isValid)
    #expect(!Shortcut(keyCode: n, modifiers: []).isValid)
    #expect(!Shortcut(keyCode: 122, modifiers: [.command]).isValid)
}

@Test func shortcutRoundTripsThroughDefaults() {
    let defaults = freshSuite()
    #expect(FeatureToggles(defaults: defaults).searchShortcut.display == "⌃⌥⌘N")
    let toggles = FeatureToggles(defaults: defaults)
    let custom = Shortcut(keyCode: 1, modifiers: [.command, .shift])
    toggles.searchShortcut = custom
    #expect(FeatureToggles(defaults: defaults).searchShortcut == custom)
    toggles.searchShortcut = .default
    #expect(FeatureToggles(defaults: defaults).searchShortcut.display == "⌃⌥⌘N")
}

@Test func permissionPollInterval() {
    #expect(permissionPollInterval(states: [.granted, .notGranted]) == 1)
    #expect(permissionPollInterval(states: [.granted, .unknown]) == 1)
    #expect(permissionPollInterval(states: [.granted, .granted]) == 5)
    #expect(permissionPollInterval(states: [.granted, .notesNotRunning]) == 5)
}
