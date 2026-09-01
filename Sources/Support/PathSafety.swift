// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The zip-slip gate. docs/SECURITY.md threats 1 and 2.
//
// An archive is a list of filenames written by a stranger. `../../../../etc/cron.d/evil`
// is a valid entry name in every container format, and it has been used in the wild
// against archivers, package managers, build tools and mobile apps for a decade. This is
// the single highest-severity defect an archive tool can ship, so the rule here is:
// refuse anything that is not provably inside the destination, and prove it against the
// filesystem rather than against the string.
//
// Three things have to hold, and checking only the first is the mistake everyone makes:
//
//   1. The entry path, read as text, must not be absolute, must not carry a drive letter,
//      and must not contain `..`.
//   2. The destination, once symlinks are resolved, must still be a descendant of the
//      root. String checks alone miss `link/passwd` where `link` is a symlink to `/etc`.
//   3. No existing component of the path may be a symlink. Checking (2) at write time is
//      too late for an archive that contains `link -> /etc` followed by `link/passwd`:
//      the member that creates the link is extracted first, and the second member then
//      travels through it. Refusing to descend through any existing link closes that,
//      and it closes it whether the link came from this archive or was already there.
//
// The check is conservative on purpose. `a/../b` resolves harmlessly to `b`, and is still
// refused, because a path that argues with itself about where it points has no business
// being written by a tool that will be pointed at a stranger's file. Fail closed.
//
// A gate cannot close a TOCTOU race by itself: between this check and the write, a local
// attacker with write access to the destination can swap a directory for a symlink. That
// window is narrowed by refusing to descend through links at all, and the residual risk
// is the same one every extractor that is not built on openat(2)/O_NOFOLLOW carries. The
// engine is a subprocess doing its own opens, so the honest statement is that this
// eliminates the archive-controlled attack and mitigates, not eliminates, the local one.

import Foundation

/// Why a destination was refused.
public enum PathSafetyError: Error, LocalizedError, Hashable, Sendable {
    /// The entry path was empty, or nothing survived stripping - `"/"`, `"."`, `"C:"`.
    /// Never treated as "the root itself", which would overwrite the destination folder.
    case emptyEntryPath(entryPath: String)

    /// The entry path contains a `..` component.
    case parentTraversal(entryPath: String)

    /// The resolved destination is not inside the root.
    case escapesRoot(entryPath: String, resolved: String)

    /// A component of the path exists and is a symbolic link, so writing would travel
    /// through it. `component` is the path of the offending link.
    case symlinkedComponent(entryPath: String, component: String)

    /// The extraction root does not exist, is not a directory, or cannot be resolved.
    /// The caller creates the destination before extracting; this means it did not.
    case rootUnavailable(root: String)

    public var errorDescription: String? {
        switch self {
        case .emptyEntryPath:
            "The archive contains an entry with no usable name."
        case .parentTraversal(let entryPath):
            "Refusing to extract '\(entryPath)': the name escapes the destination folder."
        case let .escapesRoot(entryPath, resolved):
            "Refusing to extract '\(entryPath)': it resolves to '\(resolved)', outside the destination folder."
        case let .symlinkedComponent(entryPath, component):
            "Refusing to extract '\(entryPath)': '\(component)' is a symbolic link."
        case .rootUnavailable(let root):
            "The destination folder '\(root)' is not available."
        }
    }
}

/// Resolves archive entry names to destinations that are provably inside a root.
public enum PathSafety {
    /// Tuning for the one case where strictness has a real cost.
    public struct Options: Hashable, Sendable {
        /// Allow the *last* component to be an existing symbolic link.
        ///
        /// Off by default, because an extractor that opens the leaf for writing follows
        /// the link and writes wherever it points. Turn it on only where the caller
        /// removes the link itself before writing - which is what "overwrite" means for a
        /// symlink member, and what re-extracting the same archive twice needs.
        ///
        /// Where the leaf link *points* is then deliberately not examined: the caller has
        /// undertaken to delete it, and interrogating a link that is about to stop
        /// existing proves nothing about the write that follows. Everything above the
        /// leaf is still resolved and still checked, and intermediate components are
        /// never allowed to be links whatever this says - so the promise the caller is
        /// making is narrow and local.
        public var allowExistingLeafSymlink: Bool

        /// Read `\` as a path separator as well as `/`.
        ///
        /// On by default. Old Windows tools write `\` into entry names although the ZIP
        /// appnote requires `/`, and reading it as a separator only ever splits a name
        /// into more components to check.
        public var treatsBackslashAsSeparator: Bool

        public init(allowExistingLeafSymlink: Bool = false, treatsBackslashAsSeparator: Bool = true) {
            self.allowExistingLeafSymlink = allowExistingLeafSymlink
            self.treatsBackslashAsSeparator = treatsBackslashAsSeparator
        }
    }

    /// Where `entryPath` may be written under `root`, or an error explaining why nowhere.
    ///
    /// The returned URL is built from the *resolved* root, so it is already free of the
    /// `/tmp` -> `/private/tmp` class of surprise, and it is guaranteed to be a strict
    /// descendant of that root.
    ///
    /// - Parameters:
    ///   - root: The extraction destination. Must already exist and be a directory - the
    ///     containment proof is a filesystem operation, and there is nothing to resolve
    ///     against otherwise.
    ///   - entryPath: The member name exactly as the archive gives it. Untrusted.
    public static func resolvedDestination(
        root: URL,
        entryPath: String,
        options: Options = Options()
    ) throws -> URL {
        let rootPath = try resolvedRoot(root)
        let components = try relativeComponents(ofEntryPath: entryPath, options: options)

        // Descend one component at a time, refusing to step through anything that already
        // exists as a symlink. The walk stops at the first component that does not exist
        // yet: nothing below a missing directory can exist either.
        var deepestExisting = rootPath
        var current = rootPath
        for (index, component) in components.enumerated() {
            current = current == "/" ? "/" + component : current + "/" + component

            guard let mode = linkMode(atPath: current) else { break }

            if mode & fileTypeMask == symbolicLinkMode {
                let isLeaf = index == components.count - 1
                guard isLeaf, options.allowExistingLeafSymlink else {
                    throw PathSafetyError.symlinkedComponent(entryPath: entryPath, component: current)
                }
                // Allowed, so stop here rather than record it: the resolution below must
                // not follow a link the caller is about to delete, or an outward-pointing
                // one would be reported as an escape that will never happen.
                break
            }

            deepestExisting = current
        }

        // Belt and braces: ask the kernel where the deepest part that actually exists
        // lands. After the walk above this should be the path itself, so a mismatch means
        // something the walk cannot see - a firmlink, a mount, a race - moved it, and the
        // answer is still no.
        if let resolvedExisting = realPath(deepestExisting) {
            guard isContained(resolvedExisting, in: rootPath) else {
                throw PathSafetyError.escapesRoot(entryPath: entryPath, resolved: resolvedExisting)
            }
        }

        let destination = rootPath == "/" ? "/" + components.joined(separator: "/")
                                          : rootPath + "/" + components.joined(separator: "/")
        guard isContained(destination, in: rootPath), destination != rootPath else {
            throw PathSafetyError.escapesRoot(entryPath: entryPath, resolved: destination)
        }

        return URL(fileURLWithPath: destination)
    }

    /// The textual half of the check, exposed because it is worth testing without a
    /// filesystem: absolute prefixes and drive letters stripped, `..` refused.
    ///
    /// - Returns: At least one component; never `.`, never `..`, never empty.
    public static func relativeComponents(
        ofEntryPath entryPath: String,
        options: Options = Options()
    ) throws -> [String] {
        guard !entryPath.isEmpty else {
            throw PathSafetyError.emptyEntryPath(entryPath: entryPath)
        }
        // A NUL truncates every C string the path will be handed to, so `a\0/../..` can
        // be checked as one long name here and opened as `a` further down. Refuse.
        guard !entryPath.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw PathSafetyError.emptyEntryPath(entryPath: entryPath)
        }

        let unified = options.treatsBackslashAsSeparator
            ? entryPath.replacingOccurrences(of: "\\", with: "/")
            : entryPath

        var components: [String] = []
        for rawComponent in unified.split(separator: "/", omittingEmptySubsequences: true) {
            var component = String(rawComponent)

            // `C:\Windows\x` and the drive-relative `C:x`, which is a different animal
            // and just as absolute in intent. Only meaningful in first position.
            if components.isEmpty, let stripped = strippingDriveLetter(component) {
                component = stripped
                if component.isEmpty { continue }
            }

            if component == "." { continue }
            if component == ".." {
                throw PathSafetyError.parentTraversal(entryPath: entryPath)
            }

            components.append(component)
        }

        guard !components.isEmpty else {
            throw PathSafetyError.emptyEntryPath(entryPath: entryPath)
        }
        return components
    }

    /// The canonical path of an extraction root, or `.rootUnavailable`.
    public static func resolvedRoot(_ root: URL) throws -> String {
        guard let resolved = realPath(root.path), let mode = statMode(atPath: resolved) else {
            throw PathSafetyError.rootUnavailable(root: root.path)
        }
        guard mode & fileTypeMask == directoryMode else {
            throw PathSafetyError.rootUnavailable(root: root.path)
        }
        return resolved
    }

    /// Whether `path` is `root` or below it, compared component-wise so that
    /// `/tmp/rootie` is not mistaken for a child of `/tmp/root`.
    public static func isContained(_ path: String, in root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    // MARK: - Private

    private static func strippingDriveLetter(_ component: String) -> String? {
        var remainder = Substring(component)
        guard let first = remainder.first, first.isASCII, first.isLetter else { return nil }
        remainder = remainder.dropFirst()
        guard remainder.first == ":" else { return nil }
        return String(remainder.dropFirst())
    }

    /// `realpath(3)`. Resolves every symlink and every `.`/`..`, and fails when any
    /// component is missing - which is why the caller only ever asks it about paths that
    /// exist.
    private static func realPath(_ path: String) -> String? {
        guard let buffer = realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    /// `lstat(2)`: the mode of the link itself, not of what it points at.
    private static func linkMode(atPath path: String) -> mode_t? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return status.st_mode
    }

    /// `stat(2)`: the mode after following links.
    private static func statMode(atPath path: String) -> mode_t? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return status.st_mode
    }

    private static let fileTypeMask = mode_t(S_IFMT)
    private static let symbolicLinkMode = mode_t(S_IFLNK)
    private static let directoryMode = mode_t(S_IFDIR)
}
