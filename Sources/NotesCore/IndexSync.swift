import CoreServices
import Foundation
import OSLog

public protocol NoteSource {
    func noteStamps() throws -> [NoteStamp]
    func notes(ids: [String]) throws -> [Note]
    func folders() throws -> [Folder]
    func attachmentLinkTargets(ids: [String]) throws -> [String: String]
}

extension NotesReader: NoteSource {}

extension SearchIndex {
    /// Decodes and upserts only new or changed notes, and deletes notes the source no longer lists.
    /// A body that fails to decode is indexed by title only. `linkRefs` lists the note links in a body.
    public func sync(
        from source: NoteSource,
        decode: (Data) throws -> String = { try NoteBodyDecoder.decode($0).markdown() },
        linkRefs: (Data) -> [NoteLinkRef] = { (try? NoteBodyDecoder.decode($0).linkRefs) ?? [] },
        log: (String) -> Void = { _ in }
    ) throws {
        let stamps = try source.noteStamps()
        let known = try modifiedDates()
        let listed = Set(stamps.map(\.id))
        let changed = stamps.filter { known[$0.id] != $0.modified.timeIntervalSinceReferenceDate }.map(\.id)
        try remove(known.keys.filter { !listed.contains($0) })
        guard !changed.isEmpty else { return }

        let folderNames = Dictionary(try source.folders().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for start in stride(from: 0, to: changed.count, by: 200) {
            let notes = try source.notes(ids: Array(changed[start..<min(start + 200, changed.count)]))
            let refs = notes.map { linkRefs($0.body) }
            let attachmentIDs = refs.flatMap { $0 }.compactMap { ref -> String? in
                if case .attachment(let id) = ref { return id }
                return nil
            }
            let targets = try source.attachmentLinkTargets(ids: attachmentIDs)
            try upsert(notes.indices.map { index in
                let note = notes[index]
                let links = Set(refs[index].compactMap { ref -> String? in
                    switch ref {
                    case .url(let url): NoteLink.uuid(from: url)
                    case .attachment(let id): targets[id].flatMap(NoteLink.uuid(from:))
                    }
                })
                let body: String
                do {
                    body = try decode(note.body)
                } catch {
                    log("cannot decode note \(note.id), indexing its title only: \(error)")
                    body = ""
                }
                return IndexedNote(id: note.id, title: note.title, folder: folderNames[note.folderID] ?? "",
                                   modified: note.modified, body: body,
                                   links: links.subtracting([note.id.uppercased()]).sorted())
            })
        }
    }
}

/// Runs `work` one at a time; requests made while it runs cause exactly one more run.
public actor SyncCoalescer {
    private let work: @Sendable () async -> Void
    private var running = false
    private var again = false

    public init(work: @escaping @Sendable () async -> Void) {
        self.work = work
    }

    public func request() async {
        if running {
            again = true
            return
        }
        running = true
        repeat {
            again = false
            await work()
        } while again
        running = false
    }
}

/// Watches the Notes group container's database files with FSEvents and calls `onChange` for each batch.
public final class NoteStoreWatcher: @unchecked Sendable {
    static let watchedFiles: Set<String> = ["NoteStore.sqlite", "NoteStore.sqlite-wal"]

    static func isRelevant(_ path: String) -> Bool {
        watchedFiles.contains(URL(fileURLWithPath: path).lastPathComponent)
    }

    private let directory: String
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    public init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory.path
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<NoteStoreWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if changed.prefix(count).contains(where: NoteStoreWatcher.isRelevant) { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [directory] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "NoteStoreWatcher"))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

/// Keeps the search index in step with Notes: one sync at launch, then one per batch of database file events.
public final class IndexService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "NotesCore", category: "IndexService")

    private let coalescer: SyncCoalescer
    private let watcher: NoteStoreWatcher

    public init(
        indexURL: URL,
        notesDatabaseURL: URL = NotesReader.defaultDatabaseURL
    ) {
        coalescer = SyncCoalescer {
            await Task.detached {
                do {
                    let index = try SearchIndex(url: indexURL)
                    let reader = try NotesReader(databaseURL: notesDatabaseURL)
                    try index.sync(from: reader, log: { Self.logger.error("\($0, privacy: .public)") })
                } catch {
                    Self.logger.error("cannot sync the search index: \(String(describing: error), privacy: .public)")
                }
            }.value
        }
        let coalescer = coalescer
        watcher = NoteStoreWatcher(directory: notesDatabaseURL.deletingLastPathComponent()) {
            Task { await coalescer.request() }
        }
    }

    public func start() {
        watcher.start()
        let coalescer = coalescer
        Task { await coalescer.request() }
    }
}
