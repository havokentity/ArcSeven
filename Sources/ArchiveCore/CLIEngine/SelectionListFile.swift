// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Foundation

/// Hands a selection of archive members to `7zz` without overflowing the argument list.
///
/// `ExtractRequest.selectedEntries` used to go straight onto argv. Its doc comment claimed
/// otherwise — that a list file was already in use — which is how the limit went unnoticed:
/// the note describing the hazard sat directly above the code that walked into it.
///
/// `ARG_MAX` on macOS is 1 MiB, shared between the arguments and the environment. Past it
/// `posix_spawn` fails with `E2BIG`, which surfaces as an opaque launch failure rather than
/// anything a user could act on. A few thousand deep paths is enough.
///
/// Below the threshold the entries stay on argv, so the overwhelmingly common case gains no
/// temp file, no I/O, and no cleanup to get wrong.
enum SelectionListFile {
    /// Bytes of member paths above which a list file is used instead of argv.
    ///
    /// Deliberately far below `ARG_MAX`: the switches, the executable path, the archive
    /// path and the whole environment share that budget, and the cost of crossing over
    /// early is one small temp file.
    static let threshold = 128 * 1024

    struct Prepared {
        /// Switches, which must be placed BEFORE the `--` end-of-switches marker.
        var switches: [String]
        /// Member names, which go after the archive path.
        var arguments: [String]
        /// Temp files to delete once the child has exited. Empty when argv was used.
        var temporaryFiles: [URL]
    }

    /// - Parameter entries: archive-relative member paths; `nil` or empty means everything.
    static func prepare(_ entries: [String]?) throws -> Prepared {
        guard let entries, !entries.isEmpty else {
            return Prepared(switches: [], arguments: [], temporaryFiles: [])
        }

        let budget = entries.reduce(0) { $0 + $1.utf8.count + 1 }
        guard budget > threshold else {
            return Prepared(switches: [], arguments: entries, temporaryFiles: [])
        }

        // `-i@file`, NOT a bare `@file` in the member position. The plain form is expanded
        // during command-line parsing, and the `--` end-of-switches marker that guards
        // against a member named like a switch also switches that expansion off: 7zz then
        // reads `@/tmp/.../selection.txt` as a literal member name, matches nothing, prints
        // "No files to process" and exits 0. A silent, successful-looking no-op.
        //
        // `-i@file` is a switch, so it goes before `--` and keeps both behaviours.
        //
        // `-scsUTF-8` is set in `commonSwitches`, so the file is read back as UTF-8. Without
        // it 7zz reads list files in the OEM code page and any non-ASCII member silently
        // fails to match.
        //
        // One member per line. A list-file line is matched as a WILDCARD exactly like an
        // argv name — verified, contradicting an earlier comment here — so the caller pairs
        // this with -spd. A member containing a newline still cannot be expressed in a
        // line-delimited file, so those fall back to argv below.
        let splittable = entries.filter { !$0.contains(where: \.isNewline) }
        let unsplittable = entries.filter { $0.contains(where: \.isNewline) }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-selection-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let listFile = directory.appendingPathComponent("selection.txt")

        let body = splittable.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: listFile, options: .atomic)

        return Prepared(
            switches: ["-i@" + listFile.path],
            arguments: unsplittable,
            temporaryFiles: [directory]
        )
    }
}
