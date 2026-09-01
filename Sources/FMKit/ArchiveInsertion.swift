// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Planning "add these files INTO an open archive" — the reverse of dragging out.
//
// `7zz a` stores every input under the path it was GIVEN. An absolute input stores its
// last path component (a file stores its basename; a directory stores `dirname/...`
// recursively). So the ONLY way to land a member at `docs/img/logo.png` is to run 7zz
// from a directory whose tree really contains `docs/img/logo.png`, and to pass that
// RELATIVE path. `CompressRequest.baseDirectory` provides exactly that: the engine makes
// it the child's working directory and relativises the inputs inside it.
//
// The staging tree is built out of SYMLINKS, not copies. Without `-snl` 7zz FOLLOWS
// symlinks — a linked file stores its real bytes, a linked directory is traversed into
// its children — so a tree of links weighing a few hundred bytes stands in for inputs
// of any size. Copying would double disk usage for large files for no benefit.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// A ready-to-run plan for adding files into an existing archive.
public struct ArchiveInsertionPlan: Sendable {
    /// Hand this to `engine.compress(_:)` unchanged.
    public var request: CompressRequest

    /// The staging directory of symlinks, when one was needed (`nil` for root inserts).
    public var stagingDirectory: URL?

    /// Remove the staging directory. Call AFTER the compress operation finishes —
    /// 7zz reads the inputs through the staged links during the run, and removing
    /// them mid-run would turn the add into a partial no-op.
    ///
    /// Deleting the staging tree removes the symlinks themselves, never the files
    /// they point at.
    public func cleanUp() {
        guard let stagingDirectory else { return }
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}

/// Why an insertion could not be planned.
public enum ArchiveInsertionError: Error, LocalizedError, Sendable {
    /// An input IS the archive, or is a directory that contains it.
    case archiveInsideItself
    /// Two inputs share a basename, so they would land on the same member path.
    case nameCollision(String)
    /// Nothing to add.
    case emptyInput
    /// Building the staging tree failed; the message says why.
    case stagingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .archiveInsideItself:
            "An item being added is the archive itself, or a folder that contains it."
        case .nameCollision(let name):
            "Two items are both named “\(name)”; they would land on the same entry in the archive."
        case .emptyInput:
            "There is nothing to add."
        case .stagingFailed(let reason):
            "Could not prepare the items for adding: \(reason)"
        }
    }
}

/// Plans an insertion: validation plus (for subpath inserts) the staging mkdir/symlink
/// work. Nothing here runs 7zz — the caller drives `engine.compress(_:)` with the
/// resulting request and calls ``ArchiveInsertionPlan/cleanUp()`` when it finishes.
public enum ArchiveInsertionPlanner {
    /// Plan adding `files` to `archiveURL` so they land under `destinationSubPath`
    /// ("" = the archive root). `format` comes from the open listing so the update
    /// uses the right handler; `password` is non-nil when the archive is encrypted.
    public static func plan(
        adding files: [URL],
        to archiveURL: URL,
        at destinationSubPath: String,
        format: ArchiveFormat?,
        password: String?
    ) throws -> ArchiveInsertionPlan {
        guard !files.isEmpty else { throw ArchiveInsertionError.emptyInput }
        try rejectSelfInsertion(of: files, into: archiveURL)
        try rejectBasenameCollisions(among: files)
        let subPath = try normalisedComponents(of: destinationSubPath)

        var request = CompressRequest(archiveURL: archiveURL, inputs: files)
        if let format {
            request.format = format
        }
        if let password, !password.isEmpty {
            // Updating an encrypted archive needs `-p` twice over: to read the existing
            // headers, and to encrypt the members being added. It must NOT try to flip
            // header-encryption mode on the existing archive — `-mhe` is a creation-time
            // choice already baked into the file — so `encryptFileNames` stays false,
            // which emits no `-mhe` switch at all.
            //
            // An EMPTY password is treated as "not encrypted" rather than passed
            // through: 7-Zip itself treats an empty passphrase as no encryption, and
            // `EncryptionOptions` documents `nil` as the unambiguous spelling of that.
            request.encryption = CompressRequest.EncryptionOptions(
                password: password,
                encryptFileNames: false
            )
        }

        guard !subPath.isEmpty else {
            // Root insert: absolute inputs, no staging. 7zz stores each absolute input
            // under its last path component, which for the archive root is exactly
            // where every item should land.
            return ArchiveInsertionPlan(request: request, stagingDirectory: nil)
        }

        let staging = try stage(files, under: subPath)
        request.baseDirectory = staging.root
        request.inputs = staging.inputs
        // The staged inputs are symlinks, and FOLLOWING them is the whole trick: a
        // linked file stores its real bytes and a linked directory is traversed.
        // `CompressRequest` defaults to `storeSymbolicLinks = true` (`-snl`), which
        // would store the staging links AS links — useless members holding absolute
        // paths on this machine — so it is forced off here.
        request.storeSymbolicLinks = false
        return ArchiveInsertionPlan(request: request, stagingDirectory: staging.root)
    }

    // MARK: - Validation

    /// Refuse an input that is the archive itself or an ancestor directory of it.
    ///
    /// Compressing either would feed the archive into itself while 7zz is rewriting
    /// it — the self-packing bug class the Add flow already hit once. Symlinks are
    /// resolved on BOTH sides so `/tmp/a` and `/private/tmp/a` spellings of the same
    /// location compare equal instead of slipping past a string check.
    private static func rejectSelfInsertion(of files: [URL], into archiveURL: URL) throws {
        let archive = archiveURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for input in files {
            let components = input.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let isSelfOrAncestor = components.count <= archive.count
                && Array(archive.prefix(components.count)) == components
            if isSelfOrAncestor {
                throw ArchiveInsertionError.archiveInsideItself
            }
        }
    }

    /// Every input lands at `<destination>/<basename>`, so two inputs sharing a
    /// basename would silently become one member (last one wins). Refuse instead.
    private static func rejectBasenameCollisions(among files: [URL]) throws {
        var seen = Set<String>()
        for file in files {
            let name = file.lastPathComponent
            guard seen.insert(name).inserted else {
                throw ArchiveInsertionError.nameCollision(name)
            }
        }
    }

    /// Split the destination into path components, dropping the empties produced by
    /// leading, trailing or doubled "/", and "." which means "right here" anyway.
    ///
    /// ".." is rejected outright. A destination sub-path is an IN-ARCHIVE path, and
    /// letting "../" through would stage files OUTSIDE the staging root — where they
    /// are no longer inside `baseDirectory`, so the placement mechanism silently
    /// breaks, and where the planner would be writing links into unrelated
    /// directories on disk.
    private static func normalisedComponents(of destinationSubPath: String) throws -> [String] {
        let components = destinationSubPath
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != "." }
        guard !components.contains("..") else {
            throw ArchiveInsertionError.stagingFailed(
                "the destination “\(destinationSubPath)” contains a “..” component"
            )
        }
        return components
    }

    // MARK: - Staging

    /// Build `<staging>/<sub/path>/<basename>` symlinks for every input and return the
    /// staging root plus the staged URLs, removing the tree again if anything fails.
    private static func stage(
        _ files: [URL],
        under subPath: [String]
    ) throws -> (root: URL, inputs: [URL]) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("arcseven-insert-\(UUID().uuidString)", isDirectory: true)
        var destination = root
        for component in subPath {
            destination.appendPathComponent(component, isDirectory: true)
        }
        do {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            let inputs = try files.map { file in
                let link = destination.appendingPathComponent(file.lastPathComponent)
                try manager.createSymbolicLink(at: link, withDestinationURL: file)
                return link
            }
            return (root, inputs)
        } catch {
            // Never leave a half-built staging tree behind.
            try? manager.removeItem(at: root)
            throw ArchiveInsertionError.stagingFailed(error.localizedDescription)
        }
    }
}
