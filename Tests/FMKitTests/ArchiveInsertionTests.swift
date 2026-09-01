// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The insertion planner, half pure and half live.
//
// The pure half checks the plan's SHAPE: a root insert carries the inputs untouched
// with no staging, a subpath insert carries a symlink tree plus a baseDirectory, and
// every refusal fires before anything reaches 7zz.
//
// The live half runs the plans against the real vendored 7zz — the only way to verify
// the assumptions the planner is built on: that `7zz a` stores an input under the path
// it was given, that (without `-snl`) it follows a symlinked file to its bytes and a
// symlinked directory into its children, and that `-p` alone — no `-mhe` — is what
// updating an encrypted archive needs. Skips itself when vendor/bin/7zz has not been
// built, so a bare checkout still passes.

import Foundation
import Testing
#if canImport(ArchiveCore)   // module-guard
@testable import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif

private func vendored7zzForInsertion() -> URL {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    return dir.appendingPathComponent("vendor/bin/7zz")
}

/// Whether that binary has actually been built. The live suite skips itself when it has
/// not, so `vendored7zzForInsertion()` is only ever run against a real executable.
private func vendored7zzForInsertionIsBuilt() -> Bool {
    FileManager.default.isExecutableFile(atPath: vendored7zzForInsertion().path)
}

// MARK: - Plan shape (no engine)

@Suite("Insertion planning")
struct ArchiveInsertionPlanningTests {
    /// A unique scratch directory for tests that stage real symlinks.
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arcseven-insert-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Expect planning to fail with an ``ArchiveInsertionError`` accepted by `matches`.
    private func expectPlanFailure(
        adding files: [URL],
        to archive: URL,
        at subPath: String = "",
        sourceLocation: SourceLocation = #_sourceLocation,
        matches: (ArchiveInsertionError) -> Bool
    ) {
        do {
            _ = try ArchiveInsertionPlanner.plan(
                adding: files,
                to: archive,
                at: subPath,
                format: nil,
                password: nil
            )
            Issue.record("planning succeeded unexpectedly", sourceLocation: sourceLocation)
        } catch let error as ArchiveInsertionError {
            #expect(matches(error), "unexpected error: \(error)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("non-planner error: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("A root insert stages nothing and passes the inputs as given")
    func rootPlanShape() throws {
        let inputs = [
            URL(fileURLWithPath: "/Users/anyone/Desktop/report.pdf"),
            URL(fileURLWithPath: "/Users/anyone/Downloads/notes.txt"),
        ]
        let plan = try ArchiveInsertionPlanner.plan(
            adding: inputs,
            to: URL(fileURLWithPath: "/Users/anyone/Documents/a.7z"),
            at: "",
            format: .sevenZip,
            password: nil
        )
        #expect(plan.stagingDirectory == nil)
        #expect(plan.request.baseDirectory == nil)
        #expect(plan.request.inputs == inputs)
        #expect(plan.request.updateMode == .addAndReplace)
        #expect(plan.request.encryption == nil)
        // With no base directory the engine passes the absolute paths straight
        // through, and 7zz stores each under its basename — the archive root.
        #expect(SevenZipCLIEngine.inputArguments(for: plan.request) == inputs.map(\.path))
    }

    @Test("A subpath insert stages symlinks under the destination and sets baseDirectory")
    func subpathPlanShape() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("logo.png")
        try Data("logo-bytes".utf8).write(to: input)

        let plan = try ArchiveInsertionPlanner.plan(
            adding: [input],
            to: scratch.appendingPathComponent("a.7z"),
            at: "docs/img",
            format: .sevenZip,
            password: nil
        )
        defer { plan.cleanUp() }

        let staging = try #require(plan.stagingDirectory)
        #expect(plan.request.baseDirectory == staging)

        // The staged input is a SYMLINK to the original, placed at the in-archive path.
        let staged = try #require(plan.request.inputs.first)
        #expect(staged.path.hasPrefix(staging.path))
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: staged.path)
        #expect(target == input.path)

        // What actually reaches 7zz's argv: the relative in-archive path.
        #expect(SevenZipCLIEngine.inputArguments(for: plan.request) == ["docs/img/logo.png"])

        // The links must be FOLLOWED (no -snl), or the archive would gain link members
        // holding paths on this Mac instead of real content.
        #expect(plan.request.storeSymbolicLinks == false)
        #expect(plan.request.updateMode == .addAndReplace)
    }

    @Test("Leading, trailing and doubled slashes in the destination are ignored")
    func subpathNormalisation() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: input)

        let plan = try ArchiveInsertionPlanner.plan(
            adding: [input],
            to: scratch.appendingPathComponent("a.7z"),
            at: "/docs//img/",
            format: nil,
            password: nil
        )
        defer { plan.cleanUp() }
        #expect(SevenZipCLIEngine.inputArguments(for: plan.request) == ["docs/img/x.txt"])
    }

    @Test("The caller's format and password reach the request")
    func formatAndPasswordPassthrough() throws {
        let plan = try ArchiveInsertionPlanner.plan(
            adding: [URL(fileURLWithPath: "/Users/anyone/notes.txt")],
            to: URL(fileURLWithPath: "/Users/anyone/a.zip"),
            at: "",
            format: .zip,
            password: "pw"
        )
        #expect(plan.request.format == .zip)
        let encryption = try #require(plan.request.encryption)
        #expect(encryption.password == "pw")
        // Updating must never try to flip header-encryption mode on an existing
        // archive: no `-mhe`, so encryptFileNames stays off.
        #expect(encryption.encryptFileNames == false)
    }

    @Test("No format means the default handler; no password means no encryption")
    func defaultsWhenAbsent() throws {
        let plan = try ArchiveInsertionPlanner.plan(
            adding: [URL(fileURLWithPath: "/Users/anyone/notes.txt")],
            to: URL(fileURLWithPath: "/Users/anyone/a.7z"),
            at: "",
            format: nil,
            password: nil
        )
        #expect(plan.request.format == .sevenZip)
        #expect(plan.request.encryption == nil)
    }

    @Test("An empty input list is refused")
    func emptyInputRefused() {
        expectPlanFailure(adding: [], to: URL(fileURLWithPath: "/Users/anyone/a.7z")) {
            if case .emptyInput = $0 { return true }
            return false
        }
    }

    @Test("Adding the archive to itself is refused")
    func archiveItselfRefused() {
        let archive = URL(fileURLWithPath: "/Users/anyone/Documents/a.7z")
        expectPlanFailure(adding: [archive], to: archive) {
            if case .archiveInsideItself = $0 { return true }
            return false
        }
    }

    @Test("Adding a folder that contains the archive is refused")
    func ancestorOfArchiveRefused() {
        // Adding a directory that CONTAINS the archive would recurse into the very
        // file 7zz is rewriting — the self-packing bug class Add already hit once.
        expectPlanFailure(
            adding: [URL(fileURLWithPath: "/Users/anyone/Documents")],
            to: URL(fileURLWithPath: "/Users/anyone/Documents/deep/a.7z")
        ) {
            if case .archiveInsideItself = $0 { return true }
            return false
        }
    }

    @Test("Different symlink spellings of the same ancestor are still caught")
    func symlinkSpellingRefused() throws {
        // On macOS /tmp IS a symlink to /private/tmp: the input names the folder one
        // way, the archive path names it the other. A naive string-prefix check would
        // let this through. The paths must really exist — canonicalisation only
        // rewrites the part of a path that is on disk, which an insertion always has:
        // the archive is open and the inputs were just dropped.
        let name = "arcseven-self-\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("7z".utf8).write(to: dir.appendingPathComponent("a.7z"))

        expectPlanFailure(
            adding: [URL(fileURLWithPath: "/tmp/\(name)")],
            to: URL(fileURLWithPath: "/private/tmp/\(name)/a.7z")
        ) {
            if case .archiveInsideItself = $0 { return true }
            return false
        }
    }

    @Test("A sibling whose name merely prefixes the archive's is allowed")
    func siblingPrefixAllowed() throws {
        // "/x/arc" is not an ancestor of "/x/arcseven.7z"; a string-prefix check
        // would say it is. Component comparison must not.
        _ = try ArchiveInsertionPlanner.plan(
            adding: [URL(fileURLWithPath: "/Users/anyone/arc")],
            to: URL(fileURLWithPath: "/Users/anyone/arcseven.7z"),
            at: "",
            format: nil,
            password: nil
        )
    }

    @Test("Two inputs with the same basename are refused")
    func basenameCollisionRefused() {
        expectPlanFailure(
            adding: [
                URL(fileURLWithPath: "/Users/anyone/a/readme.md"),
                URL(fileURLWithPath: "/Users/anyone/b/readme.md"),
            ],
            to: URL(fileURLWithPath: "/Users/anyone/a.7z")
        ) {
            if case .nameCollision(let name) = $0 { return name == "readme.md" }
            return false
        }
    }

    @Test("A destination containing '..' is refused")
    func parentEscapeRefused() {
        // A sub-path is an IN-ARCHIVE path. "../" would stage symlinks OUTSIDE the
        // staging root, breaking placement and touching unrelated directories.
        expectPlanFailure(
            adding: [URL(fileURLWithPath: "/Users/anyone/in.txt")],
            to: URL(fileURLWithPath: "/Users/anyone/a.7z"),
            at: "docs/../../outside"
        ) {
            if case .stagingFailed = $0 { return true }
            return false
        }
    }

    @Test("cleanUp removes the staging tree but not the originals, and is safe on a root plan")
    func cleanUpRemovesStaging() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let manager = FileManager.default
        let input = scratch.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: input)

        let plan = try ArchiveInsertionPlanner.plan(
            adding: [input],
            to: scratch.appendingPathComponent("a.7z"),
            at: "docs",
            format: nil,
            password: nil
        )
        let staging = try #require(plan.stagingDirectory)
        #expect(manager.fileExists(atPath: staging.path))

        plan.cleanUp()
        #expect(manager.fileExists(atPath: staging.path) == false)
        // Only the links go; the file they pointed at must survive.
        #expect(manager.fileExists(atPath: input.path))

        let rootPlan = try ArchiveInsertionPlanner.plan(
            adding: [input],
            to: scratch.appendingPathComponent("a.7z"),
            at: "",
            format: nil,
            password: nil
        )
        rootPlan.cleanUp()   // Nothing staged: must be a quiet no-op.
        #expect(manager.fileExists(atPath: input.path))
    }
}

// MARK: - Live, against the vendored 7zz

@Suite("Live archive insertion", .enabled(if: vendored7zzForInsertionIsBuilt()))
struct LiveArchiveInsertionTests {
    private var engine: SevenZipCLIEngine {
        SevenZipCLIEngine(executableURL: vendored7zzForInsertion(), timeZone: .gmt)
    }

    /// Build a one-member archive (`seed.txt` at the root) and hand back its URL plus
    /// a scratch directory for the test's own files. Everything is removed afterwards.
    private func withSeededArchive<T>(
        password: String? = nil,
        _ body: (_ archive: URL, _ scratch: URL) async throws -> T
    ) async throws -> T {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("arcseven-insert-live-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let seed = root.appendingPathComponent("seed.txt")
        try "seed".write(to: seed, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("demo.7z")
        var request = CompressRequest(archiveURL: archive, inputs: [seed], format: .sevenZip)
        if let password {
            // Data encryption only — the header stays listable, like the typical
            // password-protected archive a user would then drop more files into.
            request.encryption = CompressRequest.EncryptionOptions(
                password: password,
                encryptFileNames: false
            )
        }
        try await engine.compressAndWait(request)
        return try await body(archive, root)
    }

    /// The member paths 7zz reports for the archive.
    private func memberPaths(of archive: URL, password: String? = nil) async throws -> Set<String> {
        let listing = try await engine.list(
            ListRequest(archiveURL: archive, password: password, timeZone: .gmt)
        )
        return Set(listing.entries.map(\.path))
    }

    @Test("Root insert: the new member lands at its basename, existing members survive")
    func rootInsert() async throws {
        try await withSeededArchive { archive, scratch in
            let added = scratch.appendingPathComponent("added.txt")
            try "added".write(to: added, atomically: true, encoding: .utf8)

            let plan = try ArchiveInsertionPlanner.plan(
                adding: [added],
                to: archive,
                at: "",
                format: .sevenZip,
                password: nil
            )
            defer { plan.cleanUp() }
            try await engine.compressAndWait(plan.request)

            let paths = try await memberPaths(of: archive)
            #expect(paths.contains("added.txt"))
            #expect(paths.contains("seed.txt"))
        }
    }

    @Test("Subpath insert: the member lands at exactly docs/img/logo.png")
    func subpathInsert() async throws {
        try await withSeededArchive { archive, scratch in
            let logo = scratch.appendingPathComponent("logo.png")
            try Data("logo-bytes".utf8).write(to: logo)

            let plan = try ArchiveInsertionPlanner.plan(
                adding: [logo],
                to: archive,
                at: "docs/img",
                format: .sevenZip,
                password: nil
            )
            defer { plan.cleanUp() }
            try await engine.compressAndWait(plan.request)

            let paths = try await memberPaths(of: archive)
            #expect(paths.contains("docs/img/logo.png"))
            #expect(paths.contains("seed.txt"))

            // The staged symlink must have been FOLLOWED: the member holds the file's
            // bytes, not a link record pointing into this Mac's filesystem.
            let data = try await engine.readEntryData(
                ReadEntryRequest(archiveURL: archive, entryPath: "docs/img/logo.png")
            )
            #expect(String(bytes: data, encoding: .utf8) == "logo-bytes")
        }
    }

    @Test("Subpath insert of a directory: the symlinked folder is traversed")
    func subpathDirectoryInsert() async throws {
        try await withSeededArchive { archive, scratch in
            let assets = scratch.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: assets.appendingPathComponent("deep", isDirectory: true),
                withIntermediateDirectories: true
            )
            try "a".write(to: assets.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "b".write(to: assets.appendingPathComponent("deep/b.txt"), atomically: true, encoding: .utf8)

            let plan = try ArchiveInsertionPlanner.plan(
                adding: [assets],
                to: archive,
                at: "sub",
                format: .sevenZip,
                password: nil
            )
            defer { plan.cleanUp() }
            try await engine.compressAndWait(plan.request)

            // The children land under sub/<dirname>/... — proof that 7zz treats a
            // symlinked directory as a directory and walks into it.
            let paths = try await memberPaths(of: archive)
            #expect(paths.contains("sub/assets/a.txt"))
            #expect(paths.contains("sub/assets/deep/b.txt"))
            #expect(paths.contains("seed.txt"))
        }
    }

    @Test("Encrypted archive: -p alone reads the headers and encrypts the new member")
    func encryptedInsert() async throws {
        try await withSeededArchive(password: "sw0rdfish") { archive, scratch in
            let extra = scratch.appendingPathComponent("extra.txt")
            try "extra".write(to: extra, atomically: true, encoding: .utf8)

            let plan = try ArchiveInsertionPlanner.plan(
                adding: [extra],
                to: archive,
                at: "docs",
                format: .sevenZip,
                password: "sw0rdfish"
            )
            defer { plan.cleanUp() }
            try await engine.compressAndWait(plan.request)

            let listing = try await engine.list(
                ListRequest(archiveURL: archive, password: "sw0rdfish", timeZone: .gmt)
            )
            let member = try #require(listing.entries.first { $0.path == "docs/extra.txt" })
            #expect(member.isEncrypted)
            #expect(listing.entries.contains { $0.path == "seed.txt" })

            // And the member really decrypts with that password.
            let data = try await engine.readEntryData(
                ReadEntryRequest(
                    archiveURL: archive,
                    entryPath: "docs/extra.txt",
                    password: "sw0rdfish"
                )
            )
            #expect(String(bytes: data, encoding: .utf8) == "extra")
        }
    }
}
