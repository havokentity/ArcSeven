// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// `ProcessRunner` against real children — system binaries, not `7zz`, so the stream's
// own contract can be checked on a bare checkout with no vendored engine.

import Foundation
import Testing
@testable import ArchiveCore

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    /// Everything a bounded run produced, in order, plus how it ended.
    private struct Outcome {
        var output = Data()
        var completion: ProcessRunner.Completion?
        var error: (any Error)?
    }

    private func run(
        _ executable: String,
        _ arguments: [String] = [],
        byteLimit: UInt64? = nil
    ) async -> Outcome {
        var outcome = Outcome()
        do {
            for try await event in ProcessRunner.stream(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                byteLimit: byteLimit
            ) {
                switch event {
                case .standardOutput(let data): outcome.output.append(data)
                case .standardError: break
                case .finished(let completion): outcome.completion = completion
                }
            }
        } catch {
            outcome.error = error
        }
        return outcome
    }

    @Test("A bounded child delivers its output and its exit status")
    func boundedChild() async {
        let outcome = await run("/bin/echo", ["hello"], byteLimit: 1 << 20)
        #expect(String(bytes: outcome.output, encoding: .utf8) == "hello\n")
        #expect(outcome.completion?.exitCode == 0)
        #expect(outcome.error == nil)
    }

    /// `yes` writes forever. Before the fix, crossing `byteLimit` made the pump stop
    /// reading while the child kept writing: the pipe filled, the child blocked, the
    /// completion gate never fired, and this loop never returned. The time limit is
    /// what turns a regression into a failure rather than a hung test run.
    @Test("Crossing the byte limit stops the child and fails the stream", .timeLimit(.minutes(1)))
    func byteLimitEndsTheRun() async {
        let limit: UInt64 = 10_000
        let outcome = await run("/usr/bin/yes", byteLimit: limit)

        #expect(UInt64(outcome.output.count) <= limit, "nothing past the limit is delivered")
        #expect(outcome.completion == nil, "a truncated run must not be reported as finished")
        guard let error = outcome.error as? ArchiveError else {
            Issue.record("expected an ArchiveError, got \(String(describing: outcome.error))")
            return
        }
        #expect(error == .outputLimitExceeded(limit))
    }

    /// The limit is a ceiling, not a trigger: output that fits is a success.
    @Test("Output within the limit is not a failure")
    func withinLimit() async {
        let outcome = await run("/bin/echo", ["abc"], byteLimit: 4)
        #expect(outcome.output.count == 4)
        #expect(outcome.completion?.exitCode == 0)
        #expect(outcome.error == nil)
    }
}
