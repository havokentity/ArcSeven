// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The disk-directory provider, exercised against a real temporary directory.
//
// Nothing here spawns `7zz`. The provider only needs an `any ArchiveEngine` so it can
// hand one to `ArchiveFolderProvider` when the user descends into an archive, so the
// tests inject a stub that answers everything with an empty result. That keeps the
// suite fast, hermetic, and runnable on a checkout with no vendored binary — which is
// exactly what CI does.

import Foundation
import Testing
import ArchiveCore
@testable import FMKit

// MARK: - Stub engine

/// An engine that does nothing, successfully.
///
/// Conforms to the whole `ArchiveEngine` surface so the provider can be constructed;
/// only `list` is ever reached, and it answers with an empty listing.
private struct StubEngine: ArchiveEngine {
    var identifier: String { "stub" }

    func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(versionDescription: "stub")
    }

    func list(_ request: ListRequest) async throws -> ArchiveListing {
        // No entries: enough for `ArchiveFolderProvider.open` to succeed without ever
        // touching the bytes of the file the test created.
        ArchiveListing(url: request.archiveURL, entries: [])
    }

    func extract(_ request: ExtractRequest) -> ArchiveOperationStream { Self.noEvents() }
    func test(_ request: TestRequest) -> ArchiveOperationStream { Self.noEvents() }
    func compress(_ request: CompressRequest) -> ArchiveOperationStream { Self.noEvents() }
    func delete(_ request: DeleteRequest) -> ArchiveOperationStream { Self.noEvents() }
    func rename(_ request: RenameRequest) -> ArchiveOperationStream { Self.noEvents() }
    func hash(_ request: HashRequest) -> ArchiveOperationStream { Self.noEvents() }
    func benchmark(_ request: BenchmarkRequest) -> ArchiveOperationStream { Self.noEvents() }

    func readEntry(_ request: ReadEntryRequest) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private static func noEvents() -> ArchiveOperationStream {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Tests

/// A `final class` rather than a `struct` purely so `deinit` can delete the temporary
/// directory: swift-testing builds one instance per test, so each test gets its own
/// freshly populated tree and cleans up after itself even when it fails.
@Suite("Filesystem folder provider")
final class FileSystemProviderTests: Sendable {
    private let root: URL
    private let engine: any ArchiveEngine = StubEngine()

    /// Byte counts written below, so the size assertions have something exact to check.
    private static let alphaBytes = "hello world"          // 11 bytes
    private static let pngBytes = "\u{89}PNG"              // 4 bytes
    private static let notesBytes = "abc"                  // 3 bytes
    private static let fakeArchiveBytes = "not7z"          // 5 bytes

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenFSProviderTests-\(UUID().uuidString)", isDirectory: true)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        try Self.write(Self.alphaBytes, to: root.appendingPathComponent("alpha.txt"))
        try Self.write(Self.pngBytes, to: root.appendingPathComponent("image.png"))
        try Self.write(Self.notesBytes, to: root.appendingPathComponent("notes"))
        // A plain file whose *extension* claims to be an archive. `isArchive` is
        // extension-only by design, so this row must come back navigable.
        try Self.write(Self.fakeArchiveBytes, to: root.appendingPathComponent("bundle.7z"))

        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        try Self.write("nested", to: sub.appendingPathComponent("nested.txt"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private var provider: FileSystemFolderProvider {
        FileSystemFolderProvider(directoryURL: root, engine: engine)
    }

    private func item(_ name: String, in items: [FolderItem]) throws -> FolderItem {
        try #require(items.first { $0.name == name }, "no row named \(name)")
    }

    // MARK: Loading

    @Test("Every entry in the directory comes back")
    func loadsEveryChild() async throws {
        let items = try await provider.loadChildren()
        #expect(Set(items.map(\.name)) == ["alpha.txt", "image.png", "notes", "bundle.7z", "sub"])
    }

    @Test("Directories are flagged, files are not")
    func flagsDirectories() async throws {
        let items = try await provider.loadChildren()

        let sub = try item("sub", in: items)
        #expect(sub.isDirectory)
        #expect(sub.isNavigable)

        for name in ["alpha.txt", "image.png", "notes", "bundle.7z"] {
            let file = try item(name, in: items)
            #expect(!file.isDirectory, "\(name) is not a directory")
        }
    }

    @Test("Files carry their byte count; directories carry none")
    func reportsFileSizes() async throws {
        let items = try await provider.loadChildren()

        let alpha = try item("alpha.txt", in: items)
        #expect(alpha.properties[.size] == String(Self.alphaBytes.utf8.count))
        #expect(alpha.numericValue(for: .size) == UInt64(Self.alphaBytes.utf8.count))
        #expect(alpha.entry?.size == UInt64(Self.alphaBytes.utf8.count))

        let png = try item("image.png", in: items)
        #expect(png.numericValue(for: .size) == UInt64(Self.pngBytes.utf8.count))

        // A directory has no size at all — not zero, not the 4 KiB the filesystem
        // charges for the directory itself. The Size cell must render blank.
        let sub = try item("sub", in: items)
        #expect(sub.properties[.size] == nil)
        #expect(sub.numericValue(for: .size) == nil)
        #expect(ColumnModel.displayText(for: sub, column: .size).isEmpty)
    }

    @Test("Rows carry a URL and an absolute path")
    func rowsCarryTheirURL() async throws {
        let items = try await provider.loadChildren()
        let alpha = try item("alpha.txt", in: items)
        #expect(alpha.url?.lastPathComponent == "alpha.txt")
        #expect(alpha.path.hasSuffix("/alpha.txt"))
        #expect(FileManager.default.fileExists(atPath: alpha.path))
    }

    @Test("Rows carry a modification timestamp")
    func rowsCarryTimestamps() async throws {
        let items = try await provider.loadChildren()
        let alpha = try item("alpha.txt", in: items)
        #expect(alpha.entry?.modified != nil)
        // The string form matches the shape `7zz -slt` prints, so a disk row and an
        // archive row line up in the same column: yyyy-MM-dd HH:mm:ss.
        let printed = try #require(alpha.properties[.modified])
        #expect(printed.count == 19)
        #expect(printed.dropFirst(4).first == "-")
    }

    // MARK: Archive recognition

    @Test("Archive extensions are recognised")
    func recognisesArchiveExtensions() {
        for pathExtension in ["7z", "zip", "tar", "rar"] {
            let url = URL(fileURLWithPath: "/tmp/thing.\(pathExtension)")
            #expect(FileSystemFolderProvider.isArchive(url), ".\(pathExtension) is an archive")
        }
    }

    @Test("Extension matching ignores case")
    func archiveExtensionsAreCaseInsensitive() {
        for pathExtension in ["7Z", "Zip", "TAR", "RaR"] {
            let url = URL(fileURLWithPath: "/tmp/thing.\(pathExtension)")
            #expect(FileSystemFolderProvider.isArchive(url), ".\(pathExtension) is an archive")
        }
    }

    @Test("Ordinary files and extensionless files are not archives")
    func rejectsNonArchives() {
        for path in ["/tmp/readme.txt", "/tmp/logo.png", "/tmp/README", "/tmp/.hidden"] {
            #expect(!FileSystemFolderProvider.isArchive(URL(fileURLWithPath: path)), "\(path)")
        }
    }

    /// The distinction the panel depends on: an archive is a *file* that can be
    /// entered. Marking it a directory would sort it with the folders and break
    /// every size and selection rule.
    @Test("A file with an archive extension is navigable but is not a directory")
    func archiveFileIsNavigableButNotADirectory() async throws {
        let items = try await provider.loadChildren()
        let archive = try item("bundle.7z", in: items)
        #expect(archive.isNavigable)
        #expect(!archive.isDirectory)

        // A plain file is neither.
        let plain = try item("alpha.txt", in: items)
        #expect(!plain.isNavigable)
        #expect(!plain.isDirectory)
    }

    // MARK: Navigation

    @Test("parent() walks up one level")
    func parentWalksUp() async throws {
        let sub = FileSystemFolderProvider(
            directoryURL: root.appendingPathComponent("sub", isDirectory: true), engine: engine
        )
        let up = try await sub.parent()
        #expect(up?.displayPath == provider.displayPath)
        #expect(up?.kind == .fileSystem)

        // And again, to prove it is not a one-shot.
        let upTwice = try await #require(up).parent()
        #expect(upTwice?.displayPath == root.deletingLastPathComponent().standardizedFileURL.path)
    }

    @Test("parent() is nil at /")
    func parentIsNilAtRoot() async throws {
        let filesystemRoot = FileSystemFolderProvider(
            directoryURL: URL(fileURLWithPath: "/", isDirectory: true), engine: engine
        )
        let up = try await filesystemRoot.parent()
        let hasParent = up != nil
        #expect(!hasParent)
    }

    @Test("child(at:) descends into a directory")
    func childOfDirectory() async throws {
        let items = try await provider.loadChildren()
        let sub = try item("sub", in: items)

        let child = try await #require(provider.child(at: sub))
        #expect(child.kind == .fileSystem)
        #expect(child.displayPath.hasSuffix("/sub"))

        let grandchildren = try await child.loadChildren()
        #expect(grandchildren.map(\.name) == ["nested.txt"])
    }

    @Test("child(at:) is nil for a plain file")
    func childOfPlainFileIsNil() async throws {
        let items = try await provider.loadChildren()

        for name in ["alpha.txt", "image.png", "notes"] {
            let child = try await provider.child(at: try item(name, in: items))
            let descended = child != nil
            #expect(!descended, "\(name) must not be navigable")
        }
    }

    @Test("child(at:) of an archive-named file opens an archive level")
    func childOfArchiveFileIsAnArchiveLevel() async throws {
        let items = try await provider.loadChildren()
        let archive = try item("bundle.7z", in: items)

        // The stub engine answers with an empty listing, so this exercises the routing
        // decision — file plus archive extension goes to ArchiveFolderProvider — with
        // no subprocess involved.
        let child = try await #require(provider.child(at: archive))
        #expect(child.kind == .archive)
        #expect(try await child.loadChildren().isEmpty)
    }

    // MARK: Columns

    /// The per-folder-type column rule: a file on disk has no Packed Size, CRC,
    /// Method or Block, so those columns are not offered at this level at all.
    @Test("A disk folder offers no archive-only columns")
    func diskColumnsExcludeArchiveOnlyProperties() {
        let columns = provider.availableColumns

        for property in [PropID.packedSize, .crc, .method, .block, .encrypted] {
            #expect(!columns.contains(property), "\(property.rawValue) is archive-only")
        }
    }

    @Test("A disk folder offers the columns a file on disk can fill")
    func diskColumnsCoverDiskProperties() {
        let columns = provider.availableColumns
        #expect(columns.first == .name)
        for property in [PropID.name, .size, .modified, .created, .attributes] {
            #expect(columns.contains(property), "\(property.rawValue) should be offered")
        }
    }

    @Test("Kind and display path describe the directory")
    func describesItself() {
        #expect(provider.kind == .fileSystem)
        #expect(provider.displayPath.hasSuffix(root.lastPathComponent))
    }

    // MARK: Failure

    @Test("Reading a directory that does not exist throws")
    func missingDirectoryThrows() async throws {
        let missing = FileSystemFolderProvider(
            directoryURL: root.appendingPathComponent("no-such-directory", isDirectory: true),
            engine: engine
        )
        // An empty listing would be a lie: the panel would show an empty folder rather
        // than reporting that it could not read one.
        await #expect(throws: ArchiveError.self) {
            _ = try await missing.loadChildren()
        }
    }

    @Test("Reading something that is a file, not a directory, throws")
    func fileIsNotADirectory() async throws {
        let notADirectory = FileSystemFolderProvider(
            directoryURL: root.appendingPathComponent("alpha.txt"), engine: engine
        )
        await #expect(throws: ArchiveError.self) {
            _ = try await notADirectory.loadChildren()
        }
    }

    @Test("Reading a directory with no read permission throws")
    func unreadableDirectoryThrows() async throws {
        // root bypasses the permission bits, so the case cannot be provoked there.
        guard getuid() != 0 else { return }

        let fileManager = FileManager.default
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        // Restore the mode either way, or `deinit` cannot clean the tree up.
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let provider = FileSystemFolderProvider(directoryURL: locked, engine: engine)
        await #expect(throws: ArchiveError.self) {
            _ = try await provider.loadChildren()
        }
    }
}
