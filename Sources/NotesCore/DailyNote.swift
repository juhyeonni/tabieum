import Foundation

/// What Notes must do for today's note; the real one sends Apple events, so tests use a fake.
@MainActor
public protocol DailyNoteStore {
    /// The handle of a note with exactly this title in any account, else nil.
    func existingNote(titled title: String) throws -> String?
    /// The HTML body of the templates folder's note named "Daily" (case does not matter), else nil.
    func dailyTemplate() throws -> String?
    /// Creates a note in Notes' default folder and returns its handle.
    func create(html: String) throws -> String
    func show(_ handle: String) throws
}

public enum DailyNote {
    public enum Outcome: Equatable, Sendable { case opened, created }

    public static func title(for date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// The date as the heading, then the template without its own first line.
    public static func html(title: String, template: String?) -> String {
        "<div><h1>\(title)</h1></div>" + (template.map { strippingFirstLine(html: $0) } ?? "")
    }

    @MainActor
    public static func open(now: Date, in timeZone: TimeZone, store: DailyNoteStore) throws -> Outcome {
        let title = title(for: now, in: timeZone)
        if let handle = try store.existingNote(titled: title) {
            try store.show(handle)
            return .opened
        }
        try store.show(try store.create(html: html(title: title, template: try store.dailyTemplate())))
        return .created
    }
}
