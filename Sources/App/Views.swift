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
    let ai: AIFeature
    let embedding: EmbeddingState
    let install: ModelInstall
    let shortcuts: [ShortcutController]
    let showOnboarding: () -> Void
    let setRAG: (Bool) -> Void
    let chooseModel: (EmbeddingModel) -> Void
    let retryInstall: () -> Void

    var body: some View {
        TabView {
            SettingsPage {
                Card {
                    PermissionRows(status: status)
                    Button("Show Permissions Onboarding…", action: showOnboarding)
                }
                Card { ForEach(shortcuts, id: \.title) { ShortcutRecorder(controller: $0) } }
            }
            .tabItem { Label("General", systemImage: "gearshape") }
            SettingsPage {
                Card {
                    Toggle("Enable Vim mode", isOn: $toggles.vimEnabled)
                    Text("Vim-style modal editing inside Notes.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Leave Insert mode with jk", isOn: $toggles.vimJKEnabled)
                        .disabled(!toggles.vimEnabled)
                    Picker("Cursor shape", selection: $toggles.vimCursorShape) {
                        ForEach(VimCursorSetting.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .disabled(!toggles.vimEnabled)
                }
                Card {
                    Text("Markdown shortcuts").bold()
                    ForEach(MarkdownStyle.allCases, id: \.self) { style in
                        Toggle("\(style.marker.trimmingCharacters(in: .whitespacesAndNewlines))  \(style.displayName)",
                               isOn: markdownBinding(style))
                    }
                }
                Card {
                    TextField("Templates folder", text: $toggles.templateFolder)
                    Text("Type / in a note to insert one of this folder's notes, from any account.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Editor", systemImage: "keyboard") }
            SettingsPage { AITab(toggles: toggles, feature: ai) }
                .tabItem { Label("AI Assistant", systemImage: "sparkles") }
            AISearchTab(toggles: toggles, embedding: embedding, install: install, setRAG: setRAG,
                        chooseModel: chooseModel, retryInstall: retryInstall)
                .tabItem { Label("Search & Agents", systemImage: "magnifyingglass") }
        }
        .frame(minWidth: 760, minHeight: 320)
        .padding()
    }

    private func markdownBinding(_ style: MarkdownStyle) -> Binding<Bool> {
        Binding(
            get: { toggles.markdownStyles.contains(style) },
            set: { isOn in
                if isOn { toggles.markdownStyles.insert(style) } else { toggles.markdownStyles.remove(style) }
            }
        )
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
