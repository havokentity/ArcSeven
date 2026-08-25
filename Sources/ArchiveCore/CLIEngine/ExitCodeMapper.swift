// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Maps a finished `7zz` process to the engine's error model.
//
// The single most important rule here is that **exit code 1 is success**. 7-Zip
// documents it as "Warning (Non fatal error(s))": files were locked and skipped,
// a symlink could not be restored, an ACL was dropped. The operation achieved its
// goal. Treating 1 as failure is the classic integration bug — it makes ordinary
// extractions of archives containing, say, a root-owned file look like hard
// failures — so `ArchiveOperationResult` carries the warnings and the operation
// completes normally.
//
// Codes are documented by 7-Zip and were reproduced empirically (res_3 §4a.8):
//
//   0    No error.
//   1    Warning. Non-fatal. Operation completed.
//   2    Fatal error.
//   7    Command line error.
//   8    Not enough memory for the operation.
//   255  User stopped the process.
//
// 255 is overloaded and needs care. It is what you get from a real SIGINT/SIGTERM,
// and it is *also* what you get when `7zz` wants to prompt — for a password, or for
// an overwrite decision — and finds stdin closed, whereupon it prints
// "Break signaled" and quits. Those two cases need opposite handling: the first is
// a cancellation the user asked for, the second is a request for input that the UI
// must satisfy and retry. `classify` disambiguates them by looking at what the
// process actually said, which is the only signal available.

import Foundation

/// Turns a process exit status plus its diagnostic output into a result or an error.
public enum ExitCodeMapper {
    // MARK: Named codes

    /// The exit statuses `7zz` documents.
    public enum Code: Int32, Sendable, Hashable, CaseIterable {
        case ok = 0
        case warning = 1
        case fatal = 2
        case commandLine = 7
        case outOfMemory = 8
        case userBreak = 255
    }

    /// What the caller should do with a finished process.
    public enum Outcome: Sendable, Hashable {
        /// The operation achieved its goal. Warnings may still be present.
        case success
        /// The operation did not achieve its goal.
        case failure(ArchiveError)
    }

    // MARK: Classification

    /// Classify a finished process.
    ///
    /// - Parameters:
    ///   - exitCode: the child's exit status.
    ///   - terminationSignal: the signal that killed it, or `0` when it exited normally.
    ///   - stderrLines: diagnostic lines the child emitted, verbatim and in order.
    ///   - warnings: warnings accumulated by the stream parsers before termination.
    ///   - path: the archive the operation was about, for the failure detail.
    ///   - wasCancelled: `true` when *we* signalled the child because the consuming
    ///     task was cancelled. This is the authoritative disambiguation for 255 and
    ///     always wins over output sniffing.
    public static func classify(
        exitCode: Int32,
        terminationSignal: Int32 = 0,
        stderrLines: [String] = [],
        warnings: [ArchiveWarning] = [],
        path: String? = nil,
        wasCancelled: Bool = false
    ) -> Outcome {
        let detail = ArchiveFailureDetail(
            exitCode: exitCode,
            messages: stderrLines,
            warnings: warnings,
            path: path
        )

        // A signal we did not send is a crash, not an exit status. Report it as such
        // so a decoder segfault is never silently rendered as "fatal error".
        if terminationSignal != 0 && !wasCancelled {
            return .failure(.terminatedBySignal(terminationSignal, detail))
        }
        if terminationSignal != 0 && wasCancelled {
            return .failure(.cancelled)
        }

        switch Code(rawValue: exitCode) {
        case .ok, .warning:
            // 1 is success-with-warnings. See the file header.
            return .success

        case .fatal:
            // A wrong password surfaces as a fatal error whose text names it, so it
            // has to be recognised here rather than by exit code alone.
            if mentionsWrongPassword(stderrLines) {
                return .failure(.wrongPassword(detail))
            }
            return .failure(.fatal(detail))

        case .commandLine:
            return .failure(.commandLine(detail))

        case .outOfMemory:
            return .failure(.outOfMemory(detail))

        case .userBreak:
            if wasCancelled {
                return .failure(.cancelled)
            }
            if let requirement = inputRequirement(in: stderrLines) {
                return .failure(.inputRequired(requirement, detail))
            }
            // "Break signaled" with no recognisable prompt: still most likely a
            // prompt we failed to classify, but we cannot prove it. Report it as an
            // unknown input requirement rather than as a cancellation the user
            // never asked for.
            if mentionsBreak(stderrLines) {
                return .failure(.inputRequired(.unknown, detail))
            }
            return .failure(.cancelled)

        case nil:
            return .failure(.unexpectedExitCode(exitCode, detail))
        }
    }

    // MARK: Output sniffing

    /// Phrases `7zz` uses when a passphrase is wrong or missing.
    ///
    /// Matching is case-insensitive and substring-based because the exact wording
    /// varies between the header-encrypted and data-encrypted paths.
    private static let wrongPasswordPhrases = [
        "wrong password",
        "cannot open encrypted archive. wrong password",
        "data error in encrypted file. wrong password",
        "unsupported method or wrong password",
    ]

    private static let passwordPromptPhrases = [
        "enter password",
    ]

    private static let overwritePromptPhrases = [
        "would you like to replace the existing file",
        "(y)es / (n)o / (a)lways / (s)kip all / a(u)to rename all / (q)uit",
    ]

    static func mentionsWrongPassword(_ lines: [String]) -> Bool {
        contains(lines, anyOf: wrongPasswordPhrases)
    }

    static func mentionsBreak(_ lines: [String]) -> Bool {
        contains(lines, anyOf: ["break signaled"])
    }

    /// What the process was waiting for when it gave up, if we can tell.
    static func inputRequirement(in lines: [String]) -> ArchiveInputRequirement? {
        if contains(lines, anyOf: passwordPromptPhrases) { return .password }
        if contains(lines, anyOf: overwritePromptPhrases) { return .overwriteDecision }
        return nil
    }

    private static func contains(_ lines: [String], anyOf phrases: [String]) -> Bool {
        for line in lines {
            let lowered = line.lowercased()
            for phrase in phrases where lowered.contains(phrase) {
                return true
            }
        }
        return false
    }
}
