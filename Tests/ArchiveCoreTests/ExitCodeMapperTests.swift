// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Testing
@testable import ArchiveCore

@Suite("ExitCodeMapper")
struct ExitCodeMapperTests {

    /// The single most important behaviour in this file. 7-Zip exits 1 for
    /// "Warning (Non fatal error(s))" — a locked file skipped, an ACL dropped. The
    /// operation succeeded. Treating it as failure is the classic integration bug.
    @Test("Exit code 1 is success, not failure")
    func warningIsSuccess() {
        #expect(ExitCodeMapper.classify(exitCode: 1) == .success)
        #expect(ExitCodeMapper.classify(exitCode: 0) == .success)
    }

    @Test("Documented failure codes map to their own cases")
    func failureCodes() {
        guard case .failure(let fatal) = ExitCodeMapper.classify(exitCode: 2) else {
            Issue.record("2 should fail"); return
        }
        if case .fatal = fatal {} else { Issue.record("2 should be .fatal") }

        guard case .failure(let cli) = ExitCodeMapper.classify(exitCode: 7) else {
            Issue.record("7 should fail"); return
        }
        if case .commandLine = cli {} else { Issue.record("7 should be .commandLine") }

        guard case .failure(let mem) = ExitCodeMapper.classify(exitCode: 8) else {
            Issue.record("8 should fail"); return
        }
        if case .outOfMemory = mem {} else { Issue.record("8 should be .outOfMemory") }
    }

    @Test("A wrong password is recognised from the message, not the exit code")
    func wrongPassword() {
        let outcome = ExitCodeMapper.classify(
            exitCode: 2,
            stderrLines: ["ERROR: Data Error in encrypted file. Wrong password? : notes.txt"]
        )
        guard case .failure(let error) = outcome else { Issue.record("should fail"); return }
        #expect(error.needsPassword)
    }

    /// 255 is overloaded: a real cancellation, or a prompt that found stdin closed.
    /// Getting this wrong means the UI reports "cancelled" when it should be asking
    /// for a password.
    @Test("255 distinguishes cancellation from a blocked prompt")
    func userBreakIsAmbiguous() {
        let cancelled = ExitCodeMapper.classify(exitCode: 255, wasCancelled: true)
        guard case .failure(let a) = cancelled else { Issue.record("should fail"); return }
        #expect(a == .cancelled)

        let prompted = ExitCodeMapper.classify(
            exitCode: 255,
            stderrLines: ["Enter password (will not be echoed):", "Break signaled"]
        )
        guard case .failure(let b) = prompted else { Issue.record("should fail"); return }
        guard case .inputRequired(let requirement, _) = b else {
            Issue.record("should be .inputRequired, got \(b)"); return
        }
        #expect(requirement == .password)
    }

    @Test("A signal we did not send is reported as a crash")
    func uncaughtSignal() {
        let outcome = ExitCodeMapper.classify(exitCode: 0, terminationSignal: 11)
        guard case .failure(let error) = outcome else { Issue.record("should fail"); return }
        guard case .terminatedBySignal(let signal, _) = error else {
            Issue.record("should be .terminatedBySignal"); return
        }
        #expect(signal == 11)
    }

    @Test("An undocumented exit code is surfaced rather than swallowed")
    func unknownCode() {
        guard case .failure(let error) = ExitCodeMapper.classify(exitCode: 42) else {
            Issue.record("should fail"); return
        }
        guard case .unexpectedExitCode(let code, _) = error else {
            Issue.record("should be .unexpectedExitCode"); return
        }
        #expect(code == 42)
    }
}

@Suite("ExitCodeMapper — password prompt routing")
struct ExitCodeMapperPromptTests {

    /// Regression: `7zz` writes "Enter password:" to the STDOUT log (because `-bso1`
    /// routes the log there), not to stderr. Classifying against stderr alone made an
    /// encrypted archive report a generic failure, so the UI never offered to ask for
    /// a password. The engine now passes both streams.
    @Test("A password prompt on the log stream is recognised")
    func promptOnStdout() {
        let lines = [
            "Listing archive: /tmp/locked.7z",
            "Enter password:",
            "Break signaled",
        ]
        let outcome = ExitCodeMapper.classify(exitCode: 255, stderrLines: lines)
        guard case .failure(let error) = outcome else {
            Issue.record("255 with a prompt should fail"); return
        }
        #expect(error.needsPassword, "got \(error)")
    }

    @Test("A break with no recognisable prompt is not silently a cancellation")
    func breakWithoutPrompt() {
        let outcome = ExitCodeMapper.classify(exitCode: 255, stderrLines: ["Break signaled"])
        guard case .failure(let error) = outcome else { Issue.record("should fail"); return }
        guard case .inputRequired(let requirement, _) = error else {
            Issue.record("should be .inputRequired, got \(error)"); return
        }
        #expect(requirement == .unknown)
    }
}
