// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Spawns a child process and streams its output.
//
// ## Why a chunk stream rather than callbacks
//
// The obvious API here is `stream(onStandardOutput:onStandardError:)`. It does not
// survive Swift 6 strict concurrency: the callers need to *mutate* a tokenizer and a
// parser per chunk, and a `@Sendable` closure cannot capture and mutate local state.
// Handing back an `AsyncThrowingStream` of chunks instead lets the caller own that
// state in its own task and consume sequentially, which is both compilable and
// easier to reason about — chunks arrive in order, and there is exactly one consumer.
//
// ## Cancellation
//
// Cancelling the consuming task sends SIGINT to the child, then waits briefly and
// escalates to SIGKILL if it has not exited. `7zz` handles SIGINT cleanly: it unwinds,
// removes the partial archive it was writing, and exits 255.
//
// Note the honest limitation: `Foundation.Process` on Darwin exposes no way to set
// the child's process group (there is no public equivalent of `POSIX_SPAWN_SETPGROUP`),
// so we signal the child PID rather than a group. That is sufficient for `7zz`, which
// does not fork helpers. If a future engine spawns a process that does, this needs to
// move to a direct `posix_spawn` with `POSIX_SPAWN_SETPGROUP`.

import Foundation

/// Runs a child process and streams its output.
public enum ProcessRunner {
    // MARK: Types

    /// How a child finished.
    public struct Completion: Sendable, Hashable {
        /// Exit status, or 0 when the child was signalled.
        public var exitCode: Int32
        /// Signal that killed the child, or 0 when it exited normally.
        public var terminationSignal: Int32

        public init(exitCode: Int32, terminationSignal: Int32 = 0) {
            self.exitCode = exitCode
            self.terminationSignal = terminationSignal
        }
    }

    /// One thing that happened while the child ran.
    public enum Event: Sendable {
        case standardOutput(Data)
        case standardError(Data)
        /// Always the last element, unless the stream throws.
        case finished(Completion)
    }

    /// Everything a completed run produced, decoded as UTF-8.
    public struct CapturedRun: Sendable {
        public var exitCode: Int32
        public var terminationSignal: Int32
        public var standardOutput: String
        public var standardError: String
    }

    // MARK: Streaming

    /// Spawn a child and stream its output.
    ///
    /// The returned stream is cold: nothing is spawned until iteration begins.
    public static func stream(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        readChunkSize: Int = 64 * 1024,
        byteLimit: UInt64? = nil,
        currentDirectory: URL? = nil
    ) -> AsyncThrowingStream<Event, any Error> {
        let launch = Launch(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            readChunkSize: max(readChunkSize, 4096),
            byteLimit: byteLimit,
            currentDirectory: currentDirectory
        )
        return AsyncThrowingStream { continuation in
            spawn(launch, into: continuation)
        }
    }

    /// Everything `stream(...)` was asked for, carried into the spawn as one value.
    private struct Launch: Sendable {
        var executableURL: URL
        var arguments: [String]
        var environment: [String: String]?
        var standardInput: Data?
        var readChunkSize: Int
        var byteLimit: UInt64?
        var currentDirectory: URL?
    }

    // MARK: Spawn steps

    /// Start the child and wire its pipes and exit to `continuation`.
    private static func spawn(
        _ launch: Launch,
        into continuation: AsyncThrowingStream<Event, any Error>.Continuation
    ) {
        let process = makeProcess(for: launch)
        let pipes = ChildPipes()
        pipes.attach(to: process)

        // Completion needs TWO independent facts: the child has exited, and both
        // pipes have hit EOF. Emitting on either alone either truncates output or
        // reports an exit status that is not yet set.
        //
        // A run that blew through `byteLimit` is a failure, not a short success: the
        // consumer has been handed a truncated payload, and reporting exit 0 on top of
        // it is how a preview shows half a file as if it were the whole thing.
        let limit = ByteLimit(launch.byteLimit)
        let completionGate = CompletionGate { completion in
            if let byteLimit = launch.byteLimit, limit.wasExceeded {
                continuation.finish(throwing: ArchiveError.outputLimitExceeded(byteLimit))
                return
            }
            continuation.yield(.finished(completion))
            continuation.finish()
        }
        process.terminationHandler = { finished in
            completionGate.processExited(Self.completion(for: finished))
        }

        do {
            try process.run()
        } catch {
            continuation.finish(throwing: ArchiveError.launchFailed(error.localizedDescription))
            return
        }

        // Once the limit is crossed the child has nothing left to say that anyone will
        // read. Stopping it promptly matters: the alternative is decompressing the rest
        // of a multi-gigabyte member into a pipe that is only ever drained to /dev/null.
        let pid = process.processIdentifier
        let config = PumpConfig(
            continuation: continuation,
            group: DispatchGroup(),
            limit: limit,
            readChunkSize: launch.readChunkSize,
            onLimitExceeded: { kill(pid, SIGKILL) }
        )
        pump(pipes.output, wrap: Event.standardOutput, config: config)
        pump(pipes.error, wrap: Event.standardError, config: config)
        feed(launch.standardInput, into: pipes.input)

        // Both pipes at EOF: no output can be lost now.
        config.group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            completionGate.pipesDrained()
        }

        continuation.onTermination = cancellationHandler(for: process)
    }

    /// A `Process` configured but not yet run.
    private static func makeProcess(for launch: Launch) -> Process {
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        if let environment = launch.environment { process.environment = environment }
        // Working directory, not a cosmetic detail: `7zz a` stores each input under
        // the path it was GIVEN, so the only way to place a member at
        // `docs/img/logo.png` inside the archive is to run from a directory where the
        // input really is at `docs/img/logo.png`.
        if let currentDirectory = launch.currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        return process
    }

    /// Read a finished child's exit status.
    ///
    /// Reached from `terminationHandler`, never from `waitUntilExit()`.
    /// `waitUntilExit()` blocks the calling thread on Process's own internal
    /// bookkeeping, and calling it from a dispatch queue while that bookkeeping is
    /// trying to run deadlocks — reproducibly, once several processes are in flight at
    /// once. The handler is the async-safe notification.
    private static func completion(for finished: Process) -> Completion {
        let signalled = finished.terminationReason == .uncaughtSignal
        return Completion(
            exitCode: finished.terminationStatus,
            terminationSignal: signalled ? finished.terminationStatus : 0
        )
    }

    /// Drain one pipe to EOF, yielding every chunk it produces.
    ///
    /// Blocking reads go on a DISPATCH queue, never on a Task.
    ///
    /// `Task.detached` still executes on the Swift cooperative thread pool, whose
    /// width is the core count. `FileHandle.availableData` blocks, so a handful of
    /// concurrent operations is enough to occupy every pool thread and deadlock the
    /// whole process — including the code that would have drained these pipes.
    /// Dispatch's global queues grow a thread per blocked work item, which is exactly
    /// what blocking I/O needs.
    private static func pump(
        _ pipe: Pipe,
        wrap: @escaping @Sendable (Data) -> Event,
        config: PumpConfig
    ) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async(group: config.group) {
            // Always read to EOF, even after the limit. The pump that stops reading
            // leaves the child blocked on a full pipe, the child never exits, the
            // completion gate never fires, and the consumer waits forever. That is the
            // deadlock `byteLimit` used to produce on any member larger than the limit
            // plus one pipe buffer.
            while let data = readChunk(from: handle, upTo: config.readChunkSize) {
                switch config.limit.admit(UInt64(data.count)) {
                case .whole:
                    config.continuation.yield(wrap(data))
                case .truncated(let keep):
                    if keep > 0 { config.continuation.yield(wrap(data.prefix(keep))) }
                    config.onLimitExceeded()
                case .dropped:
                    continue
                }
            }
        }
    }

    /// One blocking read of at most `limit` bytes, or `nil` at EOF.
    ///
    /// `read(upToCount:)` rather than `availableData`, so the `readChunkSize` the engine
    /// asks for is actually honoured; the old call ignored it and read whatever the pipe
    /// happened to hold. A read error on a pipe we own means the other end is gone,
    /// which for the pump's purposes is EOF.
    private static func readChunk(from handle: FileHandle, upTo limit: Int) -> Data? {
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }
        return data
    }

    /// Feed stdin, then close it.
    ///
    /// Closing matters in both directions: `7zz` blocks forever on a prompt if the
    /// pipe stays open, and reports "Break signaled" (exit 255) if it is already
    /// closed when it wants input.
    private static func feed(_ standardInput: Data?, into pipe: Pipe) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = pipe.fileHandleForWriting
            if let standardInput { try? handle.write(contentsOf: standardInput) }
            try? handle.close()
        }
    }

    /// What to do when the consumer stops iterating.
    private static func cancellationHandler(
        for process: Process
    ) -> @Sendable (AsyncThrowingStream<Event, any Error>.Continuation.Termination) -> Void {
        let pid = process.processIdentifier
        return { reason in
            guard case .cancelled = reason else { return }
            // SIGINT first: 7zz unwinds and deletes the partial archive it was
            // writing. Escalate only if it does not go.
            kill(pid, SIGINT)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.75) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    // MARK: Buffered

    /// Run to completion and return the whole of both streams.
    ///
    /// For short, bounded output — version banners and listings. Anything that can
    /// produce unbounded output must use
    /// ``stream(executableURL:arguments:environment:standardInput:readChunkSize:byteLimit:)``.
    public static func runToCompletion(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        currentDirectory: URL? = nil
    ) async throws -> CapturedRun {
        var outBytes = Data()
        var errBytes = Data()
        var completion = Completion(exitCode: -1)

        for try await event in stream(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            currentDirectory: currentDirectory
        ) {
            switch event {
            case .standardOutput(let data): outBytes.append(data)
            case .standardError(let data): errBytes.append(data)
            case .finished(let done): completion = done
            }
        }

        return CapturedRun(
            exitCode: completion.exitCode,
            terminationSignal: completion.terminationSignal,
            standardOutput: EngineText.decode(outBytes),
            standardError: EngineText.decode(errBytes)
        )
    }

    // MARK: Child plumbing

    /// The three pipes a child is wired to.
    private struct ChildPipes {
        let output = Pipe()
        let error = Pipe()
        let input = Pipe()

        /// Wire these pipes to `process`.
        func attach(to process: Process) {
            process.standardOutput = output
            process.standardError = error
            process.standardInput = input
        }
    }

    /// Everything the two pipe pumps share.
    private struct PumpConfig {
        let continuation: AsyncThrowingStream<Event, any Error>.Continuation
        /// Both pumps join this group, so `notify` fires when both pipes hit EOF.
        let group: DispatchGroup
        /// Shared across both pipes: `byteLimit` caps the run, not each stream.
        let limit: ByteLimit
        /// Bytes asked for per read.
        let readChunkSize: Int
        /// Fired exactly once, by whichever pump crosses the limit.
        let onLimitExceeded: @Sendable () -> Void
    }

    // MARK: Completion gate

    /// Fires exactly once, when the child has exited *and* both pipes are drained.
    ///
    /// Those two events race, and their order is not fixed: a fast process can exit
    /// before the readers have drained the last buffer, and a process that closes its
    /// streams early can drain before it exits.
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: Completion?
        private var drained = false
        private var fired = false
        private let onComplete: @Sendable (Completion) -> Void

        init(onComplete: @escaping @Sendable (Completion) -> Void) {
            self.onComplete = onComplete
        }

        func processExited(_ completion: Completion) {
            lock.lock()
            self.completion = completion
            let ready = drained && !fired
            if ready { fired = true }
            let value = self.completion
            lock.unlock()
            if ready, let value { onComplete(value) }
        }

        func pipesDrained() {
            lock.lock()
            drained = true
            let ready = completion != nil && !fired
            if ready { fired = true }
            let value = completion
            lock.unlock()
            if ready, let value { onComplete(value) }
        }
    }

    // MARK: Shared byte budget

    /// Tracks bytes emitted against `byteLimit`, across both pipes.
    ///
    /// A lock rather than an actor: the callers are dispatch work items, not async
    /// contexts, and `await`-ing an actor from them would reintroduce exactly the
    /// cooperative-pool dependency the dispatch queues exist to avoid.
    private final class ByteLimit: @unchecked Sendable {
        /// What a pump may do with the chunk it just read.
        enum Admission {
            /// Within budget: yield the whole chunk.
            case whole
            /// This chunk crosses the limit: yield its first `keep` bytes, then stop
            /// the child. Returned exactly once per run.
            case truncated(keep: Int)
            /// The limit was already crossed: read on to EOF, yield nothing.
            case dropped
        }

        private let lock = NSLock()
        private let limit: UInt64?
        private var byteCount: UInt64 = 0
        private var exceeded = false

        init(_ limit: UInt64?) {
            self.limit = limit
        }

        var wasExceeded: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exceeded
        }

        func admit(_ count: UInt64) -> Admission {
            lock.lock()
            defer { lock.unlock() }
            guard let limit else { return .whole }
            if exceeded { return .dropped }
            let remaining = limit - byteCount
            if count <= remaining {
                byteCount += count
                return .whole
            }
            exceeded = true
            byteCount = limit
            return .truncated(keep: Int(remaining))
        }
    }
}
