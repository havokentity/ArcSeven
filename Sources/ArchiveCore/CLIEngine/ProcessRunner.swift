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

            let state = RunState()

            // Reader tasks. Detached because FileHandle reads block.
            func pump(
                _ handle: FileHandle,
                _ wrap: @escaping @Sendable (Data) -> Event
            ) -> Task<Void, Never> {
                Task.detached {
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        if let byteLimit {
                            let already = await state.addBytes(UInt64(data.count))
                            if already > byteLimit {
                                let keep = Int(byteLimit &- (already &- UInt64(data.count)))
                                if keep > 0 { continuation.yield(wrap(data.prefix(keep))) }
                                break
                            }
                        }
                        continuation.yield(wrap(data))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ArchiveError.launchFailed(error.localizedDescription))
                return
            }

            let pid = process.processIdentifier

            // Feed stdin, then close it. Closing matters: `7zz` blocks on a prompt if
            // stdin stays open, and exits 255 "Break signaled" if it is already closed
            // when it wants input.
            Task.detached {
                let handle = inPipe.fileHandleForWriting
                if let standardInput { try? handle.write(contentsOf: standardInput) }
                try? handle.close()
            }

            let outTask = pump(outPipe.fileHandleForReading, Event.standardOutput)
            let errTask = pump(errPipe.fileHandleForReading, Event.standardError)

            let waiter = Task.detached {
                _ = await outTask.result
                _ = await errTask.result
                process.waitUntilExit()
                let completion = Completion(
                    exitCode: process.terminationStatus,
                    terminationSignal: process.terminationReason == .uncaughtSignal
                        ? process.terminationStatus
                        : 0
                )
                continuation.yield(.finished(completion))
                continuation.finish()
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    // SIGINT first so 7zz can clean up its partial archive.
                    kill(pid, SIGINT)
                    Task.detached {
                        try? await Task.sleep(for: .milliseconds(750))
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
                outTask.cancel()
                errTask.cancel()
                waiter.cancel()
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

    // MARK: Shared counter

    /// Tracks bytes emitted, for `byteLimit`.
    private actor RunState {
        private var byteCount: UInt64 = 0

        /// Add to the running total and return the new value.
        func addBytes(_ count: UInt64) -> UInt64 {
            byteCount &+= count
            return byteCount
        }
    }
}
