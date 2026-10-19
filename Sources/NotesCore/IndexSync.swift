import CoreServices
import Foundation
import OSLog
import os

public protocol NoteSource {
    func noteStamps() throws -> [NoteStamp]
    func notes(ids: [String]) throws -> [Note]
    func folders() throws -> [Folder]
    func attachmentLinkTargets(ids: [String]) throws -> [String: String]
}

extension NotesReader: NoteSource {}

extension SearchIndex {
    /// Syncs the full-text index, then embeds what changed. With `embedder` nil, RAG is off: no embedder is created and all chunks are deleted.
    @discardableResult
    public func sync(
        from source: NoteSource,
        decode: (Data) throws -> String = { try NoteBodyDecoder.decode($0).markdown() },
        linkRefs: (Data) -> [NoteLinkRef] = { (try? NoteBodyDecoder.decode($0).linkRefs) ?? [] },
        log: (String) -> Void = { _ in },
        embedder: (() -> Embedder)? = nil,
        shouldPause: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        progress: (EmbeddingProgress) -> Void = { _ in },
        didSyncNotes: (Int) -> Void = { _ in }
    ) throws -> EmbedOutcome? {
        didSyncNotes(try syncNotes(from: source, decode: decode, linkRefs: linkRefs, log: log))
        guard let embedder else {
            try clearChunks()
            return nil
        }
        return try embedPending(using: embedder(), shouldPause: shouldPause, log: log, progress: progress)
    }

    /// Decodes and upserts only new or changed notes, and deletes notes the source no longer lists.
    /// A body that fails to decode is indexed by title only. `linkRefs` lists the note links in a body.
    /// Returns how many notes it indexed.
    @discardableResult
    func syncNotes(
        from source: NoteSource,
        decode: (Data) throws -> String,
        linkRefs: (Data) -> [NoteLinkRef],
        log: (String) -> Void
    ) throws -> Int {
        let stamps = try source.noteStamps()
        let known = try modifiedDates()
        let listed = Set(stamps.map(\.id))
        let changed = stamps.filter { known[$0.id] != $0.modified.timeIntervalSinceReferenceDate }.map(\.id)
        try remove(known.keys.filter { !listed.contains($0) })
        guard !changed.isEmpty else { return 0 }

        let folders = Dictionary(try source.folders().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                return IndexedNote(id: note.id, title: note.title, folder: folders[note.folderID]?.name ?? "",
                                   modified: note.modified, body: body, owner: folders[note.folderID]?.accountID ?? "",
                                   links: links.subtracting([note.id.uppercased()]).sorted())
            })
        }
        return changed.count
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

    private static let lostEvents = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    /// Whether a batch of events may hold a change to the database. Dropped or coalesced events and directory events name no file, so a
    /// path filter alone would skip them and the index would go stale.
    static func shouldSync(_ events: [(path: String, flags: FSEventStreamEventFlags)]) -> Bool {
        events.contains {
            isRelevant($0.path) || $0.flags & lostEvents != 0 || $0.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        }
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
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<NoteStoreWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let events = zip(changed.prefix(count), UnsafeBufferPointer(start: flags, count: count)).map { ($0, $1) }
            if NoteStoreWatcher.shouldSync(events) { watcher.onChange() }
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

/// Runs `action` every `interval` until cancelled. A run that is still going delays the next tick instead of overlapping it.
func repeating(every interval: Duration, _ action: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await action()
        }
    }
}

/// Keeps the search index in step with Notes: one sync at launch, one per batch of database file events, and one per interval
/// in case the file events stop arriving.
public final class IndexService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "NotesCore", category: "IndexService")

    private final class Hook: @unchecked Sendable {
        var action: (@Sendable () -> Void)?
    }

    private let coalescer: SyncCoalescer
    private let watcher: NoteStoreWatcher
    private let hook = Hook()
    private let syncInterval: Duration
    private let byTimer: OSAllocatedUnfairLock<Bool>
    private var tick: Task<Void, Never>?

    /// `onProgress` gets nil when nothing is being embedded. While RAG is off nothing is embedded and the embedder is never created.
    public init(
        indexURL: URL,
        notesDatabaseURL: URL = NotesReader.defaultDatabaseURL,
        ragEnabled: @escaping @Sendable () -> Bool = { false },
        makeEmbedder: @escaping @Sendable () -> Embedder = { ConfiguredEmbedder() },
        onProgress: @escaping @Sendable (EmbeddingProgress?) -> Void = { _ in },
        syncInterval: Duration = .seconds(60)
    ) {
        self.syncInterval = syncInterval
        let byTimer = OSAllocatedUnfairLock(initialState: false)
        self.byTimer = byTimer
        let hook = hook
        let cached = OSAllocatedUnfairLock<Embedder?>(initialState: nil)
        coalescer = SyncCoalescer {
            // ponytail: a note made just before a tick can be logged as missed; add a recency check if that is noisy
            let startedByTimer = byTimer.withLock { flag in
                defer { flag = false }
                return flag
            }
            Self.logger.info("sync started")
            let outcome = await Task.detached(priority: .background) { () -> EmbedOutcome? in
                do {
                    let index = try SearchIndex(url: indexURL)
                    let reader = try NotesReader(databaseURL: notesDatabaseURL)
                    let embedder: (() -> Embedder)? = ragEnabled() ? {
                        cached.withLock { state in
                            if let state { return state }
                            let made = makeEmbedder()
                            state = made
                            return made
                        }
                    } : nil
                    if embedder == nil { cached.withLock { $0 = nil } }
                    return try index.sync(
                        from: reader, log: { Self.logger.error("\($0, privacy: .public)") },
                        embedder: embedder, progress: { onProgress($0) },
                        didSyncNotes: { count in
                            guard startedByTimer, count > 0 else { return }
                            Self.logger.error("the timer indexed \(count) notes that the file watcher did not report")
                        })
                } catch {
                    Self.logger.error("cannot sync the search index: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }.value
            Self.logger.info("sync ended")
            if outcome == nil || outcome == .finished { onProgress(nil) }
            guard outcome == .waitingForModel else { return }
            Task {
                try? await Task.sleep(for: .seconds(10))
                hook.action?()
            }
        }
        let coalescer = coalescer
        hook.action = { Task { await coalescer.request() } }
        watcher = NoteStoreWatcher(directory: notesDatabaseURL.deletingLastPathComponent()) {
            Task { await coalescer.request() }
        }
    }

    public func start() {
        watcher.start()
        requestSync()
        let coalescer = coalescer
        let byTimer = byTimer
        tick = repeating(every: syncInterval) {
            byTimer.withLock { $0 = true }
            await coalescer.request()
        }
        let hook = hook
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            hook.action?()
        }
    }

    public func requestSync() {
        hook.action?()
    }

    deinit {
        tick?.cancel()
    }
}
