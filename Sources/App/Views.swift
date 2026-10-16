import NotesCore
import SwiftUI

extension Permission {
    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .fullDiskAccess: "Full Disk Access"
        case .automation: "Automation for Notes"
        }
    }

    var reason: String {
        switch self {
        case .accessibility: "Reads the Notes window and cursor to add keyboard features inside Notes."
        case .fullDiskAccess: "Reads the Notes database, read-only, for search. Nothing is ever written to it."
        case .automation: "Creates and edits notes through Notes itself."
        }
    }
}

struct PermissionRows: View {
    @ObservedObject var status: PermissionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Permission.allCases, id: \.self) { permission in
                row(permission, state: status.states[permission] ?? .unknown)
            }
        }
    }

    private func row(_ permission: Permission, state: PermissionState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(state == .granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).bold()
                Text(permission.reason).font(.callout).foregroundStyle(.secondary)
                Text(label(state)).font(.caption)
            }
            Spacer()
            if state != .granted {
                Button("Open System Settings") { status.request(permission) }
            }
        }
    }

    private func label(_ state: PermissionState) -> String {
        switch state {
        case .granted: "Granted"
        case .notGranted: "Not granted"
        case .notesNotRunning: "Open Notes to check"
        case .unknown: "Checking…"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var status: PermissionStatus
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions").font(.title2).bold()
            Text("Grant these in System Settings. This window updates on its own.")
                .foregroundStyle(.secondary)
            PermissionRows(status: status)
            HStack {
                Spacer()
                Button("Later", action: later).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct SettingsView: View {
    @ObservedObject var status: PermissionStatus
    @ObservedObject var toggles: FeatureToggles
    let showOnboarding: () -> Void

    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 16) {
                PermissionRows(status: status)
                Button("Show Permissions Onboarding…", action: showOnboarding)
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }
            featureTab($toggles.vimEnabled, title: "Enable Vim mode",
                       detail: "Vim-style modal editing inside Notes.")
                .tabItem { Label("Vim", systemImage: "keyboard") }
            featureTab($toggles.ragEnabled, title: "Enable RAG search",
                       detail: "Local semantic search over your notes. Runs on this Mac only.")
                .tabItem { Label("RAG", systemImage: "magnifyingglass") }
            featureTab($toggles.aiEnabled, title: "Enable AI",
                       detail: "AI features that run on this Mac only.")
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 520)
        .padding()
    }

    private func featureTab(_ isOn: Binding<Bool>, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: isOn)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
