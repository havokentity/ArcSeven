// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The zip-slip suite. Every case here is a real attack shape that has been used against
// real extractors, so a failure in this file is a shipping-blocker, not a regression.

import Foundation
import Testing
@testable import Support

@Suite("PathSafety")
struct PathSafetyTests {

    // MARK: - Fixtures

    /// A real directory on a real volume: the containment proof is a filesystem
    /// operation, so this suite cannot be written against strings alone.
    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let manager = FileManager()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenPathSafety-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try body(root)
    }

    // MARK: - Textual escapes

    @Test("`../../etc/passwd` is refused outright")
    func classicTraversalIsRefused() throws {
        try withTemporaryRoot { root in
            #expect(throws: PathSafetyError.parentTraversal(entryPath: "../../etc/passwd")) {
                try PathSafety.resolvedDestination(root: root, entryPath: "../../etc/passwd")
            }
        }
    }

    @Test("`a/../../b` is refused even though the first `..` is harmless")
    func mixedTraversalIsRefused() throws {
        try withTemporaryRoot { root in
            #expect(throws: PathSafetyError.parentTraversal(entryPath: "a/../../b")) {
                try PathSafety.resolvedDestination(root: root, entryPath: "a/../../b")
            }
        }
    }

    /// `a/../b` resolves to `b`, which is inside the root, and is refused anyway. Fail
    /// closed: a name that argues with itself about where it points is not one we write.
    @Test("`a/../b` is refused although it resolves inside the root")
    func selfCancellingTraversalIsRefused() throws {
        try withTemporaryRoot { root in
            #expect(throws: PathSafetyError.parentTraversal(entryPath: "a/../b")) {
                try PathSafety.resolvedDestination(root: root, entryPath: "a/../b")
            }
        }
    }

    @Test("An absolute path is stripped to a relative one, not honoured")
    func absolutePathIsStripped() throws {
        try withTemporaryRoot { root in
            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: "/etc/passwd")
            #expect(destination.path == resolvedRoot + "/etc/passwd")
        }
    }

    @Test("A Windows drive letter is stripped, separators and all")
    func driveLetterIsStripped() throws {
        try withTemporaryRoot { root in
            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: #"C:\Windows\x"#)
            #expect(destination.path == resolvedRoot + "/Windows/x")
        }
    }

    /// `C:x` is drive-relative, not a filename that happens to contain a colon, and it is
    /// just as absolute in intent as `C:\x`.
    @Test("A drive-relative `C:x` is stripped too")
    func driveRelativePathIsStripped() throws {
        try withTemporaryRoot { root in
            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: "C:secret.txt")
            #expect(destination.path == resolvedRoot + "/secret.txt")
        }
    }

    @Test("A backslash-separated traversal is read as a traversal")
    func backslashTraversalIsRefused() throws {
        try withTemporaryRoot { root in
            #expect(throws: PathSafetyError.self) {
                try PathSafety.resolvedDestination(root: root, entryPath: #"..\..\etc\passwd"#)
            }
        }
    }

    @Test("A UNC prefix lands inside the root rather than on the network")
    func uncPrefixIsStripped() throws {
        try withTemporaryRoot { root in
            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: #"\\server\share\file"#)
            #expect(destination.path == resolvedRoot + "/server/share/file")
        }
    }

    @Test("A NUL scalar is refused, because it truncates every C string below us")
    func embeddedNulIsRefused() throws {
        try withTemporaryRoot { root in
            #expect(throws: PathSafetyError.self) {
                try PathSafety.resolvedDestination(root: root, entryPath: "a\u{0}/../../etc")
            }
        }
    }

    @Test("Names that reduce to nothing are refused, never treated as the root itself", arguments: [
        "", "/", ".", "./", "//", "C:", "C:/",
    ])
    func emptyEntryPathsAreRefused(entryPath: String) throws {
        try withTemporaryRoot { root in
            #expect(throws: PathSafetyError.emptyEntryPath(entryPath: entryPath)) {
                try PathSafety.resolvedDestination(root: root, entryPath: entryPath)
            }
        }
    }

    // MARK: - Legitimate paths must still work

    @Test("A nested path is allowed and lands where it says")
    func nestedPathIsAllowed() throws {
        try withTemporaryRoot { root in
            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: "docs/api/v2/index.html")
            #expect(destination.path == resolvedRoot + "/docs/api/v2/index.html")
        }
    }

    @Test("`.` components and duplicate separators are tidied, not refused")
    func redundantComponentsAreTidied() throws {
        try withTemporaryRoot { root in
            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: "./a//b/./c.txt")
            #expect(destination.path == resolvedRoot + "/a/b/c.txt")
        }
    }

    @Test("A name that merely looks like a traversal is allowed")
    func dotHeavyNamesAreAllowed() throws {
        try withTemporaryRoot { root in
            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: "...secret/..stuff/a..b")
            #expect(destination.path == resolvedRoot + "/...secret/..stuff/a..b")
        }
    }

    @Test("Non-ASCII names are allowed and passed through unchanged")
    func unicodeNamesAreAllowed() throws {
        try withTemporaryRoot { root in
            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: "café/日本/naïve.txt")
            #expect(destination.path == resolvedRoot + "/café/日本/naïve.txt")
        }
    }

    @Test("Existing real directories are descended without complaint")
    func existingDirectoriesAreFine() throws {
        try withTemporaryRoot { root in
            let manager = FileManager()
            let nested = root.appendingPathComponent("a/b", isDirectory: true)
            try manager.createDirectory(at: nested, withIntermediateDirectories: true)

            let resolvedRoot = try PathSafety.resolvedRoot(root)
            let destination = try PathSafety.resolvedDestination(root: root, entryPath: "a/b/c.txt")
            #expect(destination.path == resolvedRoot + "/a/b/c.txt")
        }
    }

    // MARK: - Symlink escapes

    /// The case a string check cannot see: the path is relative, contains no `..`, and
    /// still writes to `/etc` because a component of it is a link. This is how the
    /// two-member attack works - member 1 creates `link -> /etc`, member 2 is
    /// `link/passwd`.
    @Test("A path that only escapes after symlink resolution is refused")
    func symlinkedDirectoryComponentIsRefused() throws {
        try withTemporaryRoot { root in
            let manager = FileManager()
            let outside = root.deletingLastPathComponent()
                .appendingPathComponent("ArcSevenOutside-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: outside) }

            let link = root.appendingPathComponent("link", isDirectory: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: outside)

            #expect(throws: PathSafetyError.self) {
                try PathSafety.resolvedDestination(root: root, entryPath: "link/passwd")
            }
        }
    }

    @Test("A symlink to an absolute system directory is refused")
    func symlinkToSystemDirectoryIsRefused() throws {
        try withTemporaryRoot { root in
            let manager = FileManager()
            let link = root.appendingPathComponent("etc", isDirectory: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))

            #expect(throws: PathSafetyError.self) {
                try PathSafety.resolvedDestination(root: root, entryPath: "etc/passwd")
            }
        }
    }

    /// A link that points back *inside* the root is still refused. It could be swapped
    /// for one that does not between this check and the write, and no legitimate archive
    /// needs to be extracted through one.
    @Test("Even an inward-pointing symlink component is refused")
    func inwardSymlinkComponentIsRefused() throws {
        try withTemporaryRoot { root in
            let manager = FileManager()
            let real = root.appendingPathComponent("real", isDirectory: true)
            try manager.createDirectory(at: real, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("link", isDirectory: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: real)

            #expect(throws: PathSafetyError.self) {
                try PathSafety.resolvedDestination(root: root, entryPath: "link/file.txt")
            }
        }
    }

    @Test("An existing symlink as the final component is refused by default")
    func leafSymlinkIsRefusedByDefault() throws {
        try withTemporaryRoot { root in
            let manager = FileManager()
            let target = root.deletingLastPathComponent()
                .appendingPathComponent("ArcSevenTarget-\(UUID().uuidString).txt")
            try Data("original".utf8).write(to: target)
            defer { try? manager.removeItem(at: target) }

            let link = root.appendingPathComponent("notes.txt")
            try manager.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(throws: PathSafetyError.self) {
                try PathSafety.resolvedDestination(root: root, entryPath: "notes.txt")
            }
        }
    }

    /// The opt-in says "I will delete this link before I write", so where it points is
    /// not examined - a link to `/etc/passwd` is allowed through precisely because it is
    /// about to stop existing. Everything above the leaf is still resolved and checked.
    @Test("A caller that removes the leaf link itself can opt in")
    func leafSymlinkIsAllowedWhenOptedIn() throws {
        try withTemporaryRoot { root in
            let manager = FileManager()
            let link = root.appendingPathComponent("notes.txt")
            try manager.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))

            let options = PathSafety.Options(allowExistingLeafSymlink: true)
            let destination = try PathSafety.resolvedDestination(
                root: root, entryPath: "notes.txt", options: options
            )
            #expect(destination.path == (try PathSafety.resolvedRoot(root)) + "/notes.txt")
        }
    }

    /// The opt-in is for the leaf only. An intermediate link is never negotiable.
    @Test("The leaf opt-in does not loosen intermediate components")
    func leafOptInDoesNotLoosenIntermediates() throws {
        try withTemporaryRoot { root in
            let manager = FileManager()
            let link = root.appendingPathComponent("link", isDirectory: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))

            let options = PathSafety.Options(allowExistingLeafSymlink: true)
            #expect(throws: PathSafetyError.self) {
                try PathSafety.resolvedDestination(root: root, entryPath: "link/passwd", options: options)
            }
        }
    }

    // MARK: - Root handling

    /// `/var/folders/...` is reached through the `/var -> private/var` link on every Mac,
    /// so a resolved destination that did not resolve the root too would fail its own
    /// containment check.
    @Test("A root reached through a symlink is resolved, not refused")
    func symlinkedRootIsResolved() throws {
        try withTemporaryRoot { root in
            let manager = FileManager()
            let real = root.appendingPathComponent("real", isDirectory: true)
            try manager.createDirectory(at: real, withIntermediateDirectories: true)
            let rootLink = root.appendingPathComponent("rootLink", isDirectory: true)
            try manager.createSymbolicLink(at: rootLink, withDestinationURL: real)

            let destination = try PathSafety.resolvedDestination(root: rootLink, entryPath: "a/b.txt")
            let resolvedReal = try PathSafety.resolvedRoot(real)
            #expect(destination.path == resolvedReal + "/a/b.txt")
        }
    }

    @Test("A root that does not exist is refused")
    func missingRootIsRefused() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenMissing-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: PathSafetyError.self) {
            try PathSafety.resolvedDestination(root: missing, entryPath: "a.txt")
        }
    }

    @Test("A root that is a file, not a directory, is refused")
    func fileRootIsRefused() throws {
        try withTemporaryRoot { root in
            let file = root.appendingPathComponent("not-a-directory")
            try Data("x".utf8).write(to: file)
            #expect(throws: PathSafetyError.self) {
                try PathSafety.resolvedDestination(root: file, entryPath: "a.txt")
            }
        }
    }

    // MARK: - Containment arithmetic

    /// The off-by-one that turns a containment check into a rubber stamp: a raw string
    /// prefix says `/tmp/rootie` is inside `/tmp/root`.
    @Test("Containment compares components, so a sibling with a shared prefix is outside")
    func containmentIsComponentWise() {
        #expect(PathSafety.isContained("/tmp/root", in: "/tmp/root"))
        #expect(PathSafety.isContained("/tmp/root/a/b", in: "/tmp/root"))
        #expect(!PathSafety.isContained("/tmp/rootie", in: "/tmp/root"))
        #expect(!PathSafety.isContained("/tmp", in: "/tmp/root"))
        #expect(!PathSafety.isContained("/etc/passwd", in: "/tmp/root"))
        #expect(PathSafety.isContained("/anything", in: "/"))
    }

    // MARK: - The textual half, without a filesystem

    @Test("Component splitting strips prefixes and refuses traversal")
    func relativeComponents() throws {
        #expect(try PathSafety.relativeComponents(ofEntryPath: "a/b/c") == ["a", "b", "c"])
        #expect(try PathSafety.relativeComponents(ofEntryPath: "/a/b") == ["a", "b"])
        #expect(try PathSafety.relativeComponents(ofEntryPath: #"C:\a\b"#) == ["a", "b"])
        #expect(try PathSafety.relativeComponents(ofEntryPath: "a/b/") == ["a", "b"])
        #expect(throws: PathSafetyError.self) {
            try PathSafety.relativeComponents(ofEntryPath: "a/../../b")
        }
    }

    @Test("Backslashes stay in the name when the caller says they are not separators")
    func backslashCanBeLiteral() throws {
        let options = PathSafety.Options(treatsBackslashAsSeparator: false)
        let components = try PathSafety.relativeComponents(ofEntryPath: #"a\b"#, options: options)
        #expect(components == [#"a\b"#])
    }
}
