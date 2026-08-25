// SPDX-License-Identifier: GPL-3.0-or-later
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
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            if let environment { process.environment = environment }
            // Working directory, not a cosmetic detail: `7zz a` stores each input under
            // the path it was GIVEN, so the only way to place a member at
            // `docs/img/logo.png` inside the archive is to run from a directory where the
            // input really is at `docs/img/logo.png`.
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }

            let pipes = ChildPipes()
            pipes.attach(to: process)

            // Completion needs TWO independent facts: the child has exited, and both
            // pipes have hit EOF. Emitting on either alone either truncates output or
            // reports an exit status that is not yet set.
            let completionGate = CompletionGate { completion in
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

            let config = PumpConfig(
                continuation: continuation,
                group: DispatchGroup(),
                counter: ByteCounter(),
                byteLimit: byteLimit
            )
            pump(pipes.output, wrap: Event.standardOutput, config: config)
            pump(pipes.error, wrap: Event.standardError, config: config)
            feed(standardInput, into: pipes.input)

            // Both pipes at EOF: no output can be lost now.
            config.group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                completionGate.pipesDrained()
            }

            continuation.onTermination = cancellationHandler(for: process)
        }
    }

    // MARK: Spawn steps

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
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let byteLimit = config.byteLimit {
                    let total = config.counter.add(UInt64(data.count))
                    if total > byteLimit {
                        let keep = Int(byteLimit &- (total &- UInt64(data.count)))
                        if keep > 0 { config.continuation.yield(wrap(data.prefix(keep))) }
                        break
                    }
                }
                config.continuation.yield(wrap(data))
            }
        }
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
        let counter: ByteCounter
        let byteLimit: UInt64?
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

    // MARK: Shared counter

    /// Tracks bytes emitted, for `byteLimit`.
    ///
    /// A lock rather than an actor: the callers are dispatch work items, not async
    /// contexts, and `await`-ing an actor from them would reintroduce exactly the
    /// cooperative-pool dependency the dispatch queues exist to avoid.
    private final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var byteCount: UInt64 = 0

        /// Add to the running total and return the new value.
        func add(_ count: UInt64) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            byteCount &+= count
            return byteCount
        }
    }
}
