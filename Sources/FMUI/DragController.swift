// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Dragging a file OUT of an archive, straight into Finder, without extracting it first.
//
// This is the headline macOS feature 7-Zip's own File Manager cannot offer, because
// Windows drag-and-drop has no equivalent of a *file promise*: on Windows the source has
// to materialise the bytes before the drop, so 7zFM extracts to a temp folder and drags
// that. On macOS the drop target can be told "a file of this type is coming, ask me for
// it when you actually want it", and nothing is decompressed unless the drop completes.
//
// ## The flow, end to end
//
//   1. **Drag starts.** `NSTableViewDataSource.tableView(_:pasteboardWriterForRow:)` asks
//      this controller for a pasteboard writer for one row.
//        - Row that already exists on disk -> the `NSURL` itself. Finder, Mail, Terminal
//          and everything else handle a file URL natively; wrapping it in a promise would
//          be slower and would lose Finder's move/copy/alias semantics.
//        - Row inside an archive -> an `NSFilePromiseProvider` carrying a UTType and a
//          delegate. No decompression happens here. Dragging across the screen, hovering
//          over a Dock icon, and cancelling the drag all cost exactly zero bytes.
//   2. **Finder supplies a destination.** On the drop, the receiving side (an
//      `NSFilePromiseReceiver`) picks a directory, asks the delegate for a base filename
//      via `filePromiseProvider(_:fileNameForType:)` (main thread), and then calls
//      `filePromiseProvider(_:writePromiseTo:completionHandler:)` with the exact URL to
//      write - already file-coordinated, already conflict-resolved (`foo 2.txt`).
//      That call arrives on the queue returned by `operationQueue(for:)`, which is why
//      that method must never hand back `OperationQueue.main`: Finder blocks the drop on
//      the promise, and a main-queue write would deadlock the very UI that has to draw it.
//   3. **We stream the member.** `engine.readEntry(...)` yields the member's decompressed
//      bytes as an `AsyncThrowingStream<Data, any Error>`, and each chunk goes straight to
//      a `FileHandle` at the destination. Nothing is accumulated: archives routinely hold
//      members larger than RAM, and a disk image dragged out of a `.7z` must not become a
//      12 GB `Data`.
//   4. **Completion.** The completion handler is called exactly once - success, failure or
//      cancellation. Calling it twice traps inside AppKit; never calling it leaves Finder's
//      drop spinner up forever. Both hazards are handled by ``PromiseCompletion``.
//   5. **`dragSessionEnded()`** releases the per-drag state this controller had to retain.
//
// ## Two traps this file exists to contain
//
// `NSFilePromiseProvider.delegate` is a **weak** reference. A delegate created and handed
// off inside `pasteboardWriter(for:in:)` would be deallocated before the user lifts the
// mouse, and the drop would silently produce nothing. So the controller keeps them alive.
//
// And the drag *session* ends before the promise is fulfilled: `draggingSession(_:endedAt:
// operation:)` fires when the mouse comes up, while Finder asks for the bytes a moment
// later and may take minutes to receive them. `dragSessionEnded()` therefore prunes rather
// than purges - see its documentation.

import AppKit
import UniformTypeIdentifiers
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif

// MARK: - Promise metadata

/// What an in-flight promise is about.
///
/// Parked on ``NSFilePromiseProvider/userInfo``, which is the only per-item channel the
/// promise API offers - there is no `expectedSize` property to set. Finder derives the
/// progress bar it shows from the destination file growing on disk (which is exactly why
/// step 3 above writes incrementally rather than in one shot at the end), and this value
/// gives the app side the same number for its own status readout without re-listing the
/// archive. `userInfo` is a local `id`; it is never serialised to the receiving process.
public struct PromisedArchiveMember: Sendable, Hashable {
    /// Full in-archive path of the promised member.
    public var entryPath: String
    /// Uncompressed size in bytes, when the handler reported one.
    public var byteCount: UInt64?

    public init(entryPath: String, byteCount: UInt64?) {
        self.entryPath = entryPath
        self.byteCount = byteCount
    }
}

// MARK: - DragController

/// Builds pasteboard writers for panel rows and keeps promise state alive for the
/// lifetime of a drag.
///
/// One instance per panel. `@MainActor` because it is driven entirely from
/// `NSTableView`'s data source and delegate; the actual decompression happens off it.
@MainActor
public final class DragController: NSObject {

    /// The engine every promise streams through.
    private let engine: any ArchiveEngine

    /// The queue Finder's `writePromiseTo` calls arrive on.
    ///
    /// Deliberately *not* the main queue: the write blocks until the whole member has been
    /// decompressed, and Finder will not finish the drop until the promise resolves.
    /// Bounded concurrency because each fulfilment drives its own `7zz`, and a
    /// forty-file drag should not spawn forty subprocesses at once.
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.arcseven.file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    /// The strong references that keep `NSFilePromiseProvider`'s weak delegate alive.
    private var promises: [UUID: ArchiveMemberPromise] = [:]

    /// Deferred cleanup for promises the receiver never asked about.
    private var sweepTask: Task<Void, Never>?

    /// How long after the drag ends an unrequested promise is kept.
    ///
    /// Finder asks for the bytes within a second or so of the drop; a minute is generous.
    /// A promise dropped early would find a `nil` weak delegate and simply fail to produce
    /// a file - degraded, but never a crash.
    private static let abandonedPromiseGrace = Duration.seconds(60)

    public init(engine: any ArchiveEngine) {
        self.engine = engine
        super.init()
    }

    // MARK: Building the writer

    /// Build the pasteboard writer for one row. Returns `nil` when the row cannot be
    /// dragged.
    ///
    /// - Parameters:
    ///   - item: the row being dragged.
    ///   - provider: the level it belongs to, which is what supplies the archive URL.
    public func pasteboardWriter(
        for item: FolderItem,
        in provider: any FolderProvider
    ) -> (any NSPasteboardWriting)? {

        // A row that is already a file on disk: hand over the URL and get out of the way.
        // `NSURL` is the `NSPasteboardWriting` conformer (`URL` is a struct and has none),
        // so this bridge is the whole implementation. Finder then does its own thing -
        // move within a volume, copy across one, option-drag to force a copy - none of
        // which a promise could reproduce.
        if let url = item.url {
            return url as NSURL
        }

        // Everything below here is a member inside an archive.
        guard let archive = provider as? ArchiveFolderProvider else { return nil }

        // Directories inside an archive: not draggable yet, on purpose.
        //
        // A promise for a directory is a promise for an entire subtree - every member
        // below it, recreated with its stored paths under the URL Finder hands us, with
        // one completion handler covering the lot. That is not `readEntry` at all; it is
        // `engine.extract(...)` into a destination, which needs the shared operation queue,
        // the progress sheet, the overwrite policy and the password-retry loop that land
        // in a later milestone. Returning `nil` means the row simply does not drag, which
        // is honest. Returning a promise we cannot keep would hand Finder an empty folder
        // and no error at all.
        guard !item.isDirectory else { return nil }

        let entryPath = item.entry?.path ?? item.path
        guard !entryPath.isEmpty else { return nil }

        let fileName = Self.promisedFileName(for: item, entryPath: entryPath)
        let byteCount = item.entry?.size
        let identifier = UUID()

        let promise = ArchiveMemberPromise(
            engine: engine,
            archiveURL: archive.archiveURL,
            entryPath: entryPath,
            fileName: fileName,
            byteCount: byteCount,
            queue: promiseQueue,
            onFinish: { [weak self] in
                // Fired from the promise queue when the write settles, either way.
                Task { @MainActor in self?.promises.removeValue(forKey: identifier) }
            }
        )

        let writer = NSFilePromiseProvider(
            fileType: Self.promisedFileType(for: fileName).identifier,
            delegate: promise
        )
        writer.userInfo = PromisedArchiveMember(entryPath: entryPath, byteCount: byteCount)

        // The provider's `delegate` is weak. Without this line the promise dies with the
        // stack frame that created it and the drop produces nothing.
        promises[identifier] = promise
        return writer
    }

    // MARK: Session teardown

    /// Call from `NSTableViewDelegate`'s session-ended hook to release temp state.
    ///
    /// It prunes; it does not purge. The drag session ends when the mouse comes up, but
    /// Finder asks for the promised bytes *after* that and a large member can take minutes
    /// to stream. Tearing every delegate down here would break exactly the drops that
    /// matter most. So: anything already finished goes now, anything in flight goes when
    /// it finishes, and anything the receiver never asked about (a cancelled drag, a drop
    /// on a target that only wanted the type) goes after a grace period.
    public func dragSessionEnded() {
        promises = promises.filter { !$0.value.hasFinished }

        // Scoped to the promises this session created. A drag the user is still holding
        // when the timer fires belongs to a later session and must survive it.
        let expiring = Set(promises.keys)
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            try? await Task.sleep(for: DragController.abandonedPromiseGrace)
            guard !Task.isCancelled else { return }
            self?.sweepUnclaimedPromises(among: expiring)
        }
    }

    /// Drop promises that were never requested, keeping the ones still streaming.
    private func sweepUnclaimedPromises(among expiring: Set<UUID>) {
        promises = promises.filter { identifier, promise in
            guard expiring.contains(identifier) else { return true }
            return promise.hasStartedWriting && !promise.hasFinished
        }
    }

    // MARK: Naming and typing

    /// A safe base filename for the promised member.
    ///
    /// Finder is handed a *base* name, never a path: it decides the directory and resolves
    /// collisions itself. A stored name containing `/` is malformed (7-Zip normalises `\`
    /// at parse time, so a surviving separator means the archive lied about its own
    /// structure) and is flattened rather than trusted, so nothing can steer the write out
    /// of the directory the receiver chose.
    private static func promisedFileName(for item: FolderItem, entryPath: String) -> String {
        let raw = item.name.isEmpty ? (entryPath as NSString).lastPathComponent : item.name
        let flattened = raw.replacingOccurrences(of: "/", with: "_")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return "Untitled"
        }
        return trimmed
    }

    /// The UTType the promise advertises, derived from the member's extension.
    ///
    /// `NSFilePromiseProvider` raises an ObjC exception if the type conforms to neither
    /// `public.data` nor `public.folder`, and an unknown extension can resolve to an
    /// abstract type that does neither - hence the explicit fallback to `.data` rather
    /// than just the `??`.
    private static func promisedFileType(for fileName: String) -> UTType {
        let fileExtension = (fileName as NSString).pathExtension
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension),
              type.conforms(to: .data)
        else {
            return .data
        }
        return type
    }
}

// MARK: - One promised member

/// Fulfils the promise for a single archive member.
///
/// Not `@MainActor`. AppKit annotates `filePromiseProvider(_:writePromiseTo:completionHandler:)`
/// `NS_SWIFT_NONISOLATED` and genuinely calls it on the queue from ``operationQueue(for:)``,
/// while the other two delegate methods are `NS_SWIFT_UI_ACTOR` and are written as such
/// below. Every stored property is either an immutable, `Sendable` `let` or guarded by
/// `lock`, which is what `@unchecked Sendable` asserts here.
private final class ArchiveMemberPromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {

    private let engine: any ArchiveEngine
    private let archiveURL: URL
    private let entryPath: String
    private let fileName: String
    private let byteCount: UInt64?
    private let queue: OperationQueue

    /// Told when the write settles, so the controller can stop retaining this object.
    private let onFinish: @Sendable () -> Void

    private let lock = NSLock()
    private var startedWriting = false
    private var finishedWriting = false
    private var writeTask: Task<Void, Never>?

    init(
        engine: any ArchiveEngine,
        archiveURL: URL,
        entryPath: String,
        fileName: String,
        byteCount: UInt64?,
        queue: OperationQueue,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.engine = engine
        self.archiveURL = archiveURL
        self.entryPath = entryPath
        self.fileName = fileName
        self.byteCount = byteCount
        self.queue = queue
        self.onFinish = onFinish
        super.init()
    }

    /// `true` once the receiver has asked for the bytes.
    var hasStartedWriting: Bool { lock.withLock { startedWriting } }

    /// `true` once the completion handler has been called.
    var hasFinished: Bool { lock.withLock { finishedWriting } }

    /// Stop an in-flight stream. Not called during a normal drop; here so the write is
    /// interruptible rather than merely abandonable.
    func cancel() {
        lock.withLock { writeTask }?.cancel()
    }

    // MARK: NSFilePromiseProviderDelegate

    /// The base name Finder should use. Called on the main thread, before any writing.
    @MainActor
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        fileName
    }

    /// The queue `writePromiseTo` is issued on.
    ///
    /// Spelled `operationQueue(for:)` in Swift - that is how AppKit imports
    /// `-operationQueueForFilePromiseProvider:`. Omitting it would default to the *main*
    /// queue and hang the drag for as long as decompression takes.
    @MainActor
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    /// Stream the member to the URL the receiver supplied.
    ///
    /// Arrives off the main thread. Returning before the completion handler fires is not
    /// only allowed but expected - the handler is the signal, not the return.
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        let completion = PromiseCompletion(completionHandler)
        lock.withLock { startedWriting = true }

        // Bridge from the completion-handler world into the async one. The whole body is
        // a single do/catch with one `settle` call per branch, so the handler is reached
        // on every path - a thrown engine error, a cancelled task, a full disk - and
        // exactly once, which `PromiseCompletion` then enforces regardless.
        let task = Task.detached(priority: .userInitiated) { [self] in
            do {
                try await streamMember(to: url)
                settle(completion, with: nil)
            } catch {
                // Never leave a truncated file behind: a half-written member that Finder
                // reports as delivered is worse than a failed drop.
                try? FileManager.default.removeItem(at: url)
                settle(completion, with: error)
            }
        }
        lock.withLock { writeTask = task }
    }

    // MARK: Streaming

    /// Decompress one member straight to disk, a chunk at a time.
    private func streamMember(to destination: URL) async throws {
        let manager = FileManager.default

        // "Always use the supplied URL" - the receiver has already coordinated it and
        // resolved any name collision. We only make sure we are writing a fresh file.
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw ArchiveError.io("Could not create \(destination.path).")
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let request = ReadEntryRequest(
            archiveURL: archiveURL,
            entryPath: entryPath,
            // No password plumbing on the drag path yet: an encrypted member fails the
            // promise with `.wrongPassword` and Finder reports the copy as failed. Wrong
            // only in that it should prompt; never wrong in what it writes.
            password: nil,
            formatOverride: nil,
            // The default 256 MiB cap guards *previews*, which buffer into memory and can
            // be aimed at a decompression bomb. A drag is an explicit request to
            // materialise this exact member, and it streams to disk rather than to RAM,
            // so the cap here would only break legitimate large files.
            maximumByteCount: nil
        )

        for try await chunk in engine.readEntry(request) {
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
        }
        try handle.synchronize()
    }

    // MARK: Completion

    /// Mark the write settled, answer the receiver, then release the controller's hold.
    ///
    /// Order matters: Finder is unblocked before we let ourselves be deallocated, and the
    /// running task retains `self` until this method returns either way.
    private func settle(_ completion: PromiseCompletion, with error: (any Error)?) {
        lock.withLock {
            finishedWriting = true
            writeTask = nil
        }
        completion.finish(error)
        onFinish()
    }
}

// MARK: - Exactly-once completion

/// Wraps a file-promise completion handler so it is called once and only once.
///
/// Both failure modes are fatal to the drag and neither is theoretical: calling the
/// handler twice trips an assertion inside AppKit's promise machinery, and never calling
/// it leaves the receiver waiting on a promise that will never resolve - in Finder, a copy
/// sheet that sits at zero until the app quits. The `deinit` is the belt to the lock's
/// braces: if this object is ever dropped without settling, the drag fails cleanly instead
/// of hanging.
private final class PromiseCompletion: @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable ((any Error)?) -> Void)?

    init(_ handler: @escaping @Sendable ((any Error)?) -> Void) {
        self.handler = handler
    }

    /// Call the handler if it has not been called yet. Subsequent calls do nothing.
    func finish(_ error: (any Error)?) {
        let pending: (@Sendable ((any Error)?) -> Void)? = lock.withLock {
            defer { handler = nil }
            return handler
        }
        // Invoked outside the lock: the receiver's handler is AppKit code and must never
        // run with one of ours held.
        pending?(error)
    }

    deinit {
        finish(ArchiveError.cancelled)
    }
}
