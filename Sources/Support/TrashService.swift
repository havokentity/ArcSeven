// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Delete on a Mac means "move to Trash".
//
// 7zFM's file-pane Delete calls SHFileOperation with FOF_ALLOWUNDO, so the items land in
// the Recycle Bin and Undo works; Shift+Delete is the separate, explicitly-confirmed
// permanent path. The Mac equivalent of the first is FileManager.trashItem, and it is not
// a courtesy: it puts the items where the user expects to find them, keeps Finder's
// "Put Back" working because trashItem records the original location, and is the only
// form of delete that is undoable.
//
// Nothing here unlinks. A permanent delete belongs behind its own confirmation and its
// own code path, not one flag away from the everyday one.

import Foundation

/// Why a move to Trash failed.
public enum TrashError: Error, LocalizedError, Hashable, Sendable {

    /// The item is already gone.
    case notFound(path: String)

    /// No permission to move the item - it or its parent is not writable.
    case notPermitted(path: String)

    /// The volume has no Trash: most network shares, read-only volumes, disk images
    /// mounted read-only, and some FUSE filesystems. There is no way to trash an item
    /// there, so the UI must offer the permanent delete instead and say why.
    case volumeHasNoTrash(path: String)

    /// Anything else, with whatever the system said.
    case failed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            "'\(path)' no longer exists."
        case .notPermitted(let path):
            "'\(path)' could not be moved to the Trash because you do not have permission."
        case .volumeHasNoTrash(let path):
            "The volume containing '\(path)' does not have a Trash."
        case .failed(let path, let reason):
            "'\(path)' could not be moved to the Trash: \(reason)"
        }
    }
}

/// One item that made it to the Trash.
public struct TrashOutcome: Hashable, Sendable {
    /// Where the item used to be.
    public let source: URL
    /// Where it is now, when the system reported it. Worth keeping: it is what an Undo
    /// implementation moves back, and what a "Show in Trash" command reveals.
    public let trashedURL: URL?
}

/// One item that did not.
public struct TrashFailure: Hashable, Sendable {
    public let source: URL
    public let error: TrashError
}

/// The result of trashing a selection.
public struct TrashSummary: Hashable, Sendable {
    public let trashed: [TrashOutcome]
    public let failures: [TrashFailure]

    public var isCompleteSuccess: Bool { failures.isEmpty }
}

/// Moves files and folders to the Trash.
public enum TrashService {

    /// Move one item to the Trash.
    ///
    /// - Returns: The item's new location inside the Trash, when the system reports one.
    @discardableResult
    public static func trash(_ url: URL) throws -> URL? {
        // A private FileManager rather than `.default`: this can be called from any
        // task, and an instance with no delegate has no shared state to contend for.
        let manager = FileManager()
        var resulting: NSURL?
        do {
            try manager.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw mapped(error, for: url)
        }
        return resulting.map { $0 as URL }
    }

    /// Move a selection to the Trash, carrying on past failures.
    ///
    /// Deleting twelve files and stopping at the third leaves the user with a mess and no
    /// way to tell what happened, so every item is attempted and the outcome is reported
    /// as a whole - the same shape the Windows original's error list has.
    public static func trash(_ urls: [URL]) -> TrashSummary {
        var trashed: [TrashOutcome] = []
        var failures: [TrashFailure] = []

        for url in urls {
            do {
                let destination = try trash(url)
                trashed.append(TrashOutcome(source: url, trashedURL: destination))
            } catch let error as TrashError {
                failures.append(TrashFailure(source: url, error: error))
            } catch {
                failures.append(
                    TrashFailure(
                        source: url,
                        error: .failed(path: url.path, reason: error.localizedDescription)
                    )
                )
            }
        }

        return TrashSummary(trashed: trashed, failures: failures)
    }

    // MARK: - Private

    private static func mapped(_ error: any Error, for url: URL) -> TrashError {
        guard let cocoa = error as? CocoaError else {
            return .failed(path: url.path, reason: error.localizedDescription)
        }
        switch cocoa.code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return .notFound(path: url.path)
        case .fileWriteNoPermission, .fileReadNoPermission:
            return .notPermitted(path: url.path)
        case .featureUnsupported, .fileWriteUnsupportedScheme, .fileWriteVolumeReadOnly:
            return .volumeHasNoTrash(path: url.path)
        default:
            return .failed(path: url.path, reason: cocoa.localizedDescription)
        }
    }
}
