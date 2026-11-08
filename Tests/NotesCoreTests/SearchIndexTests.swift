import Foundation
import Testing
@testable import NotesCore

private final class FakeNotes: NoteSource, @unchecked Sendable {
    var notes: [String: Note] = [:]

    func set(_ id: String, title: String, body: String, modified: Double = 1) {
        notes[id] = Note(id: id, title: title, folderID: "f1", created: Date(timeIntervalSinceReferenceDate: 0),
                         modified: Date(timeIntervalSinceReferenceDate: modified), snippet: nil, body: Data(body.utf8))
    }

    func noteStamps() throws -> [NoteStamp] { notes.values.map { NoteStamp(id: $0.id, modified: $0.modified) } }
    func notes(ids: [String]) throws -> [Note] { ids.compactMap { notes[$0] } }
    func folders() throws -> [Folder] { [Folder(id: "f1", name: "Work", accountID: "a", parentID: nil)] }

    var attachmentTargets: [String: String] = [:]
    func attachmentLinkTargets(ids: [String]) throws -> [String: String] { attachmentTargets.filter { ids.contains($0.key) } }
}

private func refs(_ data: Data) -> [NoteLinkRef] {
    String(decoding: data, as: UTF8.self).split(separator: " ").compactMap { token in
        if token.hasPrefix("att:") { return .attachment(String(token.dropFirst(4))) }
        if token.hasPrefix("applenotes:") { return .url(String(token)) }
        return nil
    }
}

private func uuid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }
private func link(_ n: Int) -> String { "applenotes:note/\(uuid(n).lowercased())?ownerIdentifier=x" }

private struct BadBody: Error {}

private func plain(_ data: Data) throws -> String {
    let text = String(decoding: data, as: UTF8.self)
    if text == "BAD" { throw BadBody() }
    return text
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
}

private func makeIndex(_ source: FakeNotes, url: URL = tempURL()) throws -> SearchIndex {
    let index = try SearchIndex(url: url)
    try index.sync(from: source, decode: plain, linkRefs: refs)
    return index
}

@Suite struct SearchIndexTests {
    @Test func titleMatchRanksAboveBodyMatch() throws {
        let source = FakeNotes()
        source.set("body", title: "Groceries", body: "remember the budget numbers")
        source.set("title", title: "Budget", body: "monthly plan")
        let results = try makeIndex(source).search("budget")
        #expect(results.map(\.id) == ["title", "body"])
        #expect(results[0].folder == "Work")
        #expect(results[1].snippet.contains("budget"))
    }

    @Test func prefixAndCaseInsensitive() throws {
        let source = FakeNotes()
        source.set("a", title: "Meeting notes", body: "")
        source.set("b", title: "x", body: "오늘 회의를 했다")
        source.set("c", title: "y", body: "회의록 정리")
        let index = try makeIndex(source)
        #expect(try index.search("MEET").map(\.id) == ["a"])
        #expect(Set(try index.search("회의").map(\.id)) == ["b", "c"])
    }

    @Test func notesWithAllTermsComeFirst() throws {
        let source = FakeNotes()
        source.set("a", title: "apple pie", body: "")
        source.set("b", title: "apple", body: "")
        #expect(try makeIndex(source).search("apple pie").map(\.id) == ["a", "b"])
    }

    @Test func hostileQueriesNeverFail() throws {
        let source = FakeNotes()
        source.set("a", title: "near and", body: "text")
        let index = try makeIndex(source)
        for query in ["\"", "-", "*", "(", ")", "NEAR", "AND", "a\"b", "NEAR(a b)", "- * (", "\"unclosed"] {
            _ = try index.search(query)
        }
        #expect(try index.search("").isEmpty)
        #expect(try index.search("   ").isEmpty)
        #expect(try index.search("near AND").map(\.id) == ["a"])
    }

    @Test func attachmentAndTextLinksBothMakeEdges() throws {
        let source = FakeNotes()
        source.set(uuid(2), title: "B", body: "")
        source.set(uuid(1), title: "A", body: "see att:ATT1", modified: 1)
        source.set(uuid(3), title: "C", body: "pasted \(link(2))", modified: 2)
        source.attachmentTargets = ["ATT1": "applenotes:note/\(uuid(2))?ownerIdentifier=x"]
        let index = try makeIndex(source)
        #expect(try index.backlinks(to: uuid(2)).map(\.id) == [uuid(3), uuid(1)])
    }

    @Test func selfUnknownAndDuplicateLinksAddNoRows() throws {
        let source = FakeNotes()
        source.set(uuid(2), title: "B", body: "me \(link(2)) gone \(link(99)) web applenotes:other/x")
        source.set(uuid(1), title: "A", body: "\(link(2)) \(link(2)) att:ATT1")
        source.attachmentTargets = ["ATT1": link(2)]
        let index = try makeIndex(source)
        #expect(try index.backlinks(to: uuid(2)).map(\.id) == [uuid(1)])
        #expect(try index.backlinks(to: uuid(1)).isEmpty)
    }

    @Test func reindexAndDeleteUpdateEdges() throws {
        let source = FakeNotes()
        source.set(uuid(2), title: "B", body: "")
        source.set(uuid(1), title: "A", body: link(2))
        source.set(uuid(3), title: "C", body: link(2))
        let index = try makeIndex(source)
        #expect(try index.backlinks(to: uuid(2)).count == 2)
        source.set(uuid(1), title: "A", body: "no link", modified: 2)
        source.notes[uuid(3)] = nil
        try index.sync(from: source, decode: plain, linkRefs: refs)
        #expect(try index.backlinks(to: uuid(2)).isEmpty)
    }

    @Test func backlinksCarryTitleFolderAndDateNewestFirst() throws {
        let source = FakeNotes()
        source.set(uuid(2), title: "B", body: "")
        source.set(uuid(1), title: "Old", body: link(2), modified: 5)
        source.set(uuid(3), title: "New", body: link(2), modified: 9)
        let backlinks = try makeIndex(source).backlinks(to: uuid(2))
        #expect(backlinks == [
            Backlink(id: uuid(3), title: "New", folder: "Work", modified: Date(timeIntervalSinceReferenceDate: 9)),
            Backlink(id: uuid(1), title: "Old", folder: "Work", modified: Date(timeIntervalSinceReferenceDate: 5)),
        ])
    }

    @Test func coreDataIDParsing() {
        #expect(CurrentNote.key(coreDataID: "x-coredata://ABC-123/ICNote/p123") == 123)
        #expect(CurrentNote.key(coreDataID: "x-coredata://ABC-123/ICFolder/p123") == nil)
        for bad in ["", "x-coredata://ABC/ICNote/", "x-coredata://ABC/ICNote/123", "x-coredata://ABC/ICNote/pxyz",
                    "x-coredata:///ICNote/p1", "x-coredata://ABC/ICNote/p1/extra", "http://ABC/ICNote/p1"] {
            #expect(CurrentNote.key(coreDataID: bad) == nil)
        }
    }

    @Test func linkRefsFindTextLinksAndLinkAttachments() throws {
        let runs = [
            Encode.run(1, link: link(2)),
            Encode.run(1, extra: Encode.bytes(12, Encode.string(1, "ATT1") + Encode.string(2, NoteLink.linkAttachmentUTI))),
            Encode.run(1, attachment: .some("public.jpeg")),
        ]
        let document = try NoteBodyDecoder.decode(Encode.gzipBody("abc", runs))
        #expect(document.linkRefs == [.url(link(2)), .attachment("ATT1")])
    }

    @Test func firstSyncIndexesEveryNote() throws {
        let source = FakeNotes()
        for i in 0..<5 { source.set("n\(i)", title: "common \(i)", body: "") }
        #expect(try makeIndex(source).search("common").count == 5)
    }

    @Test func secondSyncDecodesOnlyChangedNote() throws {
        let source = FakeNotes()
        source.set("a", title: "one", body: "alpha")
        source.set("b", title: "two", body: "beta")
        let index = try makeIndex(source)
        source.set("b", title: "two", body: "gamma", modified: 2)
        nonisolated(unsafe) var decoded: [String] = []
        try index.sync(from: source, decode: { decoded.append(String(decoding: $0, as: UTF8.self)); return try plain($0) })
        #expect(decoded == ["gamma"])
        #expect(try index.search("gamma").map(\.id) == ["b"])
        #expect(try index.search("beta").isEmpty)
    }

    @Test func removedNoteDisappears() throws {
        let source = FakeNotes()
        source.set("a", title: "keep", body: "")
        source.set("b", title: "drop", body: "")
        let index = try makeIndex(source)
        source.notes["b"] = nil
        try index.sync(from: source, decode: plain)
        #expect(try index.search("drop").isEmpty)
        #expect(try index.search("keep").count == 1)
    }

    @Test func undecodableBodyIsFoundByTitle() throws {
        let source = FakeNotes()
        source.set("a", title: "Findable", body: "BAD")
        nonisolated(unsafe) var logged: [String] = []
        let index = try SearchIndex(url: tempURL())
        try index.sync(from: source, decode: plain, log: { logged.append($0) })
        #expect(try index.search("findable").map(\.id) == ["a"])
        #expect(logged.count == 1)
    }

    @Test func otherSchemaVersionIsRebuilt() throws {
        let source = FakeNotes()
        source.set("a", title: "kept", body: "")
        let url = tempURL()
        _ = try makeIndex(source, url: url)
        let raw = try SQLiteConnection(url: url, readOnly: false)
        try raw.run("PRAGMA user_version = 99")
        let rebuilt = try SearchIndex(url: url)
        #expect(try rebuilt.search("kept").isEmpty)
        try rebuilt.sync(from: source, decode: plain)
        #expect(try rebuilt.search("kept").count == 1)
    }

    @Test func readOnlyConnectionSearchesButCannotWrite() throws {
        let source = FakeNotes()
        source.set("a", title: "shared", body: "")
        let url = tempURL()
        let writer = try makeIndex(source, url: url)
        let reader = try SearchIndex(url: url, readOnly: true)
        #expect(try reader.search("shared").count == 1)
        #expect(throws: SQLiteError.self) { try reader.remove(["a"]) }
        source.set("b", title: "later", body: "", modified: 2)
        try writer.sync(from: source, decode: plain)
        #expect(try reader.search("later").count == 1)
    }

    @Test func tenThousandNotesSearchUnder100ms() throws {
        let source = FakeNotes()
        let korean = "오늘 회의에서 주간 일정과 프로젝트 예산을 논의했다 "
        let english = "the quick brown fox jumps over the lazy dog while planning the meeting agenda "
        for i in 0..<10_000 {
            let text = String((0..<30).map { _ in i % 2 == 0 ? korean : english }.joined().prefix(2000))
            source.set("n\(i)", title: "Note \(i)", body: text + " unique\(i)")
        }
        let index = try makeIndex(source)
        let clock = ContinuousClock()
        var results: [SearchResult] = []
        let elapsed = try clock.measure { results = try index.search("meeting") }
        #expect(results.count == 20)
        #expect(results.allSatisfy { !$0.snippet.isEmpty })
        #expect(elapsed < .milliseconds(100))
    }

    @Test func coalescerRunsOneMoreTimeForEventsDuringARun() async {
        let log = Counter()
        let gate = Gate()
        let coalescer = SyncCoalescer {
            let n = await log.next()
            if n == 1 { await gate.wait() }
        }
        let first = Task { await coalescer.request() }
        await gate.waitUntilWaiting()
        await coalescer.request()
        await coalescer.request()
        await coalescer.request()
        await gate.open()
        await first.value
        #expect(await log.count == 2)
    }

    @Test func watcherIgnoresShmFile() {
        #expect(NoteStoreWatcher.isRelevant("/x/NoteStore.sqlite"))
        #expect(NoteStoreWatcher.isRelevant("/x/NoteStore.sqlite-wal"))
        #expect(!NoteStoreWatcher.isRelevant("/x/NoteStore.sqlite-shm"))
    }

    @Test func watcherSyncsOnLostOrDirectoryEventsAndIgnoresOtherFiles() {
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        func flag(_ value: Int) -> FSEventStreamEventFlags { FSEventStreamEventFlags(value) }
        #expect(NoteStoreWatcher.shouldSync([("/x/NoteStore.sqlite-wal", file)]))
        #expect(NoteStoreWatcher.shouldSync([("/x/Other", flag(kFSEventStreamEventFlagMustScanSubDirs))]))
        #expect(NoteStoreWatcher.shouldSync([("/x/Other", flag(kFSEventStreamEventFlagUserDropped))]))
        #expect(NoteStoreWatcher.shouldSync([("/x/Other", flag(kFSEventStreamEventFlagKernelDropped))]))
        #expect(NoteStoreWatcher.shouldSync([("/x/Media", flag(kFSEventStreamEventFlagItemIsDir))]))
        #expect(!NoteStoreWatcher.shouldSync([("/x/NoteStore.sqlite-shm", file), ("/x/Media/a.png", file)]))
        #expect(!NoteStoreWatcher.shouldSync([]))
    }

    @Test func repeatingRunsTheActionWithoutAnyEventUntilCancelled() async {
        let runs = Counter()
        let task = repeating(every: .milliseconds(10)) { _ = await runs.next() }
        for _ in 0..<200 where await runs.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await task.value
        let seen = await runs.count
        #expect(seen >= 3)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await runs.count == seen)
    }
}

private actor Counter {
    var count = 0
    func next() -> Int { count += 1; return count }
}

private actor Gate {
    private var opened = false
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilWaiting() async {
        while !waiting { await Task.yield() }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
