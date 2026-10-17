import AppKit
import NotesCore

/// "Check for Updates…": one request to GitHub when the person clicks, then a window. It never runs on its own.
@MainActor
enum UpdateAction {
    static func run() async {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let name = ProductInfo.main?.name ?? "This app"
        guard let url = ProductInfo.main?.repository.flatMap(UpdateCheck.endpoint(repository:)) else {
            return show("Couldn't check for updates", "The release location is not set in this build.")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                return show("No release yet", "\(name) \(current) is the only version so far.")
            }
            guard let release = UpdateCheck.latest(from: data) else {
                return show("Couldn't check for updates", "GitHub sent an answer this app does not understand.")
            }
            guard UpdateCheck.isNewer(release.version, than: current) else {
                return show("You're up to date", "\(name) \(current) is the latest version.")
            }
            let alert = NSAlert()
            alert.messageText = "\(name) \(release.version) is available"
            alert.informativeText = "You have \(current). The release page has the download and what changed."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
        } catch {
            show("Couldn't check for updates", "Check your internet connection and try again.")
        }
    }

    private static func show(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}
