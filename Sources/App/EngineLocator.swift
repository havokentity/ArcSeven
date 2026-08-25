// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Finds the bundled `7zz`.
//
// In a shipping build it is at `ArcSeven.app/Contents/Helpers/7zz`, put there by the
// copy-files phase in project.yml and signed with the same Team ID as the app — which
// is what satisfies library validation without needing any
// `com.apple.security.cs.*` entitlement.
//
// During development the binary may not be in a bundle at all, so the repo's
// `vendor/bin/7zz` is used as a fallback. That fallback is developer convenience
// only; a release build must never depend on it, and `Scripts/verify-release.sh`
// checks the bundled copy is present.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

enum EngineLocator {
    /// Where the helper was found, for the About box and for diagnostics.
    struct Located {
        var url: URL
        var source: String
    }

    /// Locate `7zz`, or `nil` when it has not been built.
    static func locate() -> Located? {
        // Contents/Helpers is where the copy-files phase puts it. Spell the path out
        // rather than trusting `url(forAuxiliaryExecutable:)`, which only searches
        // Contents/MacOS and silently returns nil here.
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
        if FileManager.default.isExecutableFile(atPath: helpers.path) {
            return Located(url: helpers, source: "bundle")
        }

        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: "7zz"),
           FileManager.default.isExecutableFile(atPath: auxiliary.path) {
            return Located(url: auxiliary, source: "bundle/MacOS")
        }

        for candidate in developmentCandidates() where
            FileManager.default.isExecutableFile(atPath: candidate.path) {
            return Located(url: candidate, source: "development checkout")
        }
        return nil
    }

    /// `vendor/bin/7zz` relative to the running binary, walking up out of
    /// `.build/debug` or `ArcSeven.app/Contents/MacOS`.
    private static func developmentCandidates() -> [URL] {
        var results: [URL] = []
        var directory = Bundle.main.bundleURL
        for _ in 0..<8 {
            results.append(directory.appendingPathComponent("vendor/bin/7zz"))
            directory.deleteLastPathComponent()
        }
        return results
    }

    /// Build the engine, or `nil` when the helper is missing.
    static func makeEngine() -> (engine: SevenZipCLIEngine, located: Located)? {
        guard let located = locate() else { return nil }
        return (SevenZipCLIEngine(executableURL: located.url), located)
    }
}
