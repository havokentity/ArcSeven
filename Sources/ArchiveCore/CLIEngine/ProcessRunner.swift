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
        byteLimit: UInt64? = nil
    ) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            if let environment { process.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            let inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe

            // Completion needs TWO independent facts: the child has exited, and both
            // pipes have hit EOF. Emitting on either alone either truncates output or
            // reports an exit status that is not yet set.
            let completionGate = CompletionGate { completion in
                continuation.yield(.finished(completion))
                continuation.finish()
            }

            // `terminationHandler`, never `waitUntilExit()`.
            //
            // `waitUntilExit()` blocks the calling thread on Process's own internal
            // bookkeeping, and calling it from a dispatch queue while that bookkeeping
            // is trying to run deadlocks — reproducibly, once several processes are in
            // flight at once. The handler is the async-safe notification.
            process.terminationHandler = { finished in
                let signalled = finished.terminationReason == .uncaughtSignal
                completionGate.processExited(
                    Completion(
                        exitCode: finished.terminationStatus,
                        terminationSignal: signalled ? finished.terminationStatus : 0
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ArchiveError.launchFailed(error.localizedDescription))
                return
            }

            let pid = process.processIdentifier
            let counter = ByteCounter()
            let group = DispatchGroup()

            // Blocking reads go on a DISPATCH queue, never on a Task.
            //
            // `Task.detached` still executes on the Swift cooperative thread pool,
            // whose width is the core count. `FileHandle.availableData` blocks, so a
            // handful of concurrent operations is enough to occupy every pool thread
            // and deadlock the whole process — including the code that would have
            // drained these pipes. Dispatch's global queues grow a thread per blocked
            // work item, which is exactly what blocking I/O needs.
            func pump(
                _ handle: FileHandle,
                _ wrap: @escaping @Sendable (Data) -> Event
            ) {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        if let byteLimit {
                            let total = counter.add(UInt64(data.count))
                            if total > byteLimit {
                                let keep = Int(byteLimit &- (total &- UInt64(data.count)))
                                if keep > 0 { continuation.yield(wrap(data.prefix(keep))) }
                                break
                            }
                        }
                        continuation.yield(wrap(data))
                    }
                }
            }

            pump(outPipe.fileHandleForReading, Event.standardOutput)
            pump(errPipe.fileHandleForReading, Event.standardError)

            // Feed stdin, then close it.
            //
            // Closing matters in both directions: `7zz` blocks forever on a prompt if
            // the pipe stays open, and reports "Break signaled" (exit 255) if it is
            // already closed when it wants input.
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = inPipe.fileHandleForWriting
                if let standardInput { try? handle.write(contentsOf: standardInput) }
                try? handle.close()
            }

            // Both pipes at EOF: no output can be lost now.
            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                completionGate.pipesDrained()
            }

            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                // SIGINT first: 7zz unwinds and deletes the partial archive it was
                // writing. Escalate only if it does not go.
                kill(pid, SIGINT)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.75) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }

    // MARK: Buffered

    /// Run to completion and return the whole of both streams.
    ///
    /// For short, bounded output — version banners and listings. Anything that can
    /// produce unbounded output must use ``stream(executableURL:arguments:environment:standardInput:readChunkSize:byteLimit:)``.
    public static func runToCompletion(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil
    ) async throws -> CapturedRun {
        var outBytes = Data()
        var errBytes = Data()
        var completion = Completion(exitCode: -1)

        for try await event in stream(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput
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
            standardOutput: String(decoding: outBytes, as: UTF8.self),
            standardError: String(decoding: errBytes, as: UTF8.self)
        )
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
