// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// "Remember in Keychain", from the checkbox to the next open.
//
// Through 0.1.5 `PasswordPromptResult.storeInKeychain` was set from the checkbox and read
// by nobody: a grep for `Keychain` across the tree found `PasswordDialogController.swift`
// and nothing else, while the checkbox's tooltip promised the archive would open without
// asking again.
//
// A write with no read would be the same bug wearing a Keychain hat, so the read is what
// most of this file is about: the assertions are on whether the archive ends up OPEN,
// which it can only be if the stored passphrase was fetched and tried.
//
// The store is substituted rather than real — running this against the tester's login
// keychain would prompt them for access and leave items behind. The real Security calls
// are covered by `Tests/FMKitTests/KeychainArchivePasswordStoreTests.swift`.

import AppKit
import Foundation
import Testing
@testable import ArchiveCore
@testable import FMKit
@testable import FMUI

// MARK: - Doubles

/// An `ArchivePasswordStore` in a dictionary, recording what it was asked to do.
private final class FakePasswordStore: ArchivePasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private(set) var saveCount = 0
    private(set) var removeCount = 0

    init(seeded: [URL: String] = [:]) {
        for (url, password) in seeded { items[url.standardizedFileURL.path] = password }
    }

    func password(forArchiveAt url: URL) -> String? {
        lock.withLock { items[url.standardizedFileURL.path] }
    }

    @discardableResult
    func save(_ password: String, forArchiveAt url: URL) -> Bool {
        lock.withLock {
            items[url.standardizedFileURL.path] = password
            saveCount += 1
        }
        return true
    }

    func removePassword(forArchiveAt url: URL) {
        lock.withLock {
            items[url.standardizedFileURL.path] = nil
            removeCount += 1
        }
    }
}

/// Lists an archive only when handed the right passphrase; otherwise fails the way `7zz`
/// does for an encrypted header, which is the condition the open path retries on.
private struct LockedArchiveEngine: ArchiveEngine {
    let expectedPassword: String

    var identifier: String { "locked" }

    func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(versionDescription: "locked")
    }

    func list(_ request: ListRequest) async throws -> ArchiveListing {
        guard request.password == expectedPassword else {
            throw ArchiveError.wrongPassword(
                ArchiveFailureDetail(exitCode: 2, messages: ["Wrong password?"])
            )
        }
        return ArchiveListing(
            url: request.archiveURL,
            entries: [ArchiveEntry(path: "secret.txt", isDirectory: false)]
        )
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

@MainActor
@Suite("Keychain password wiring")
struct KeychainPasswordWiringTests {
    private static let archive = URL(fileURLWithPath: "/Users/x/Downloads/secret.7z")
    private static let passphrase = "correct horse battery staple"

    private func makeWindow(
        store: FakePasswordStore
    ) -> (MainWindowController, PanelViewController) {
        let controller = MainWindowController(
            startingAt: URL(fileURLWithPath: NSTemporaryDirectory()),
            engine: LockedArchiveEngine(expectedPassword: Self.passphrase)
        )
        controller.passwordStore = store
        return (controller, controller.panels[0])
    }

    private func isOpen(_ panel: PanelViewController) -> Bool {
        (panel.provider as? ArchiveFolderProvider)?.archiveURL == Self.archive
    }

    // MARK: The read path

    /// The half that makes the checkbox mean anything. Without it the write is dead
    /// storage and the user is prompted every time, which is the bug verbatim.
    @Test("A remembered passphrase opens the archive with no prompt")
    func rememberedPassphraseOpensTheArchive() async {
        let store = FakePasswordStore(seeded: [Self.archive: Self.passphrase])
        let (controller, panel) = makeWindow(store: store)

        await controller.openArchive(at: Self.archive, in: panel, password: nil)

        #expect(isOpen(panel), "the stored passphrase was never tried")
        #expect(controller.window?.attachedSheet == nil, "a prompt went up anyway")
    }

    @Test("With nothing remembered the archive stays shut until the user answers")
    func withoutAStoredPassphraseNothingOpens() async {
        let store = FakePasswordStore()
        let (controller, panel) = makeWindow(store: store)

        await controller.openArchive(at: Self.archive, in: panel, password: nil)

        #expect(!isOpen(panel), "an archive opened without any passphrase at all")
        #expect(store.saveCount == 0)
    }

    // MARK: The write path

    @Test("Ticking the box stores the passphrase once the archive opens")
    func tickingTheBoxStores() async {
        let store = FakePasswordStore()
        let (controller, panel) = makeWindow(store: store)

        await controller.openArchive(
            at: Self.archive, in: panel, password: Self.passphrase,
            origin: .typed(remember: true)
        )

        #expect(isOpen(panel))
        #expect(store.password(forArchiveAt: Self.archive) == Self.passphrase)
        #expect(store.saveCount == 1)
    }

    @Test("Leaving the box unticked stores nothing")
    func unticketedPassphraseIsNotStored() async {
        let store = FakePasswordStore()
        let (controller, panel) = makeWindow(store: store)

        await controller.openArchive(
            at: Self.archive, in: panel, password: Self.passphrase,
            origin: .typed(remember: false)
        )

        #expect(isOpen(panel))
        #expect(store.password(forArchiveAt: Self.archive) == nil)
        #expect(store.saveCount == 0)
    }

    /// A typo must never be what gets remembered: the archive has to open first.
    @Test("A wrong passphrase is not stored even with the box ticked")
    func wrongPassphraseIsNotStored() async {
        let store = FakePasswordStore()
        let (controller, panel) = makeWindow(store: store)

        await controller.openArchive(
            at: Self.archive, in: panel, password: "hunter2",
            origin: .typed(remember: true)
        )

        #expect(!isOpen(panel))
        #expect(store.saveCount == 0)
        #expect(store.password(forArchiveAt: Self.archive) == nil)
    }

    /// An empty answer means "find out whether this archive needs a password at all"
    /// (see `PasswordDialogController.validate`), not "remember the empty passphrase".
    @Test("An empty passphrase is never stored")
    func emptyPassphraseIsNotStored() async {
        let store = FakePasswordStore()
        let controller = MainWindowController(
            startingAt: URL(fileURLWithPath: NSTemporaryDirectory()),
            engine: LockedArchiveEngine(expectedPassword: "")
        )
        controller.passwordStore = store
        let panel = controller.panels[0]

        await controller.openArchive(
            at: Self.archive, in: panel, password: "", origin: .typed(remember: true)
        )

        #expect(isOpen(panel))
        #expect(store.saveCount == 0)
    }

    // MARK: Eviction

    /// An archive re-encrypted under a new passphrase leaves a stale item behind. If it
    /// survived, every open would retry it and the user would never reach the prompt.
    @Test("A remembered passphrase that stops working is forgotten")
    func staleItemIsEvicted() async {
        let store = FakePasswordStore(seeded: [Self.archive: "the old one"])
        let (controller, panel) = makeWindow(store: store)

        await controller.openArchive(at: Self.archive, in: panel, password: nil)

        #expect(!isOpen(panel))
        #expect(store.removeCount == 1, "the stale item was kept")
        #expect(store.password(forArchiveAt: Self.archive) == nil)
    }

    @Test("A passphrase typed at the prompt does not evict anything")
    func typedFailureLeavesTheStoreAlone() async {
        let store = FakePasswordStore(seeded: [Self.archive: Self.passphrase])
        let (controller, panel) = makeWindow(store: store)

        await controller.openArchive(
            at: Self.archive, in: panel, password: "hunter2", origin: .typed(remember: false)
        )

        #expect(store.removeCount == 0)
        #expect(store.password(forArchiveAt: Self.archive) == Self.passphrase)
    }

    // MARK: The other consumer

    /// Adding files to an encrypted archive prompts too. "Opens without asking again"
    /// should not hold for one command and not the next.
    @Test("The insertion path uses the remembered passphrase as well")
    func insertionPathReadsTheStore() async {
        let store = FakePasswordStore(seeded: [Self.archive: Self.passphrase])
        let (controller, _) = makeWindow(store: store)

        var answered: String?
        controller.password(forArchiveAt: Self.archive) { answered = $0 }
        #expect(answered == Self.passphrase)
        // Read-only: only a verified open is allowed to write.
        #expect(store.saveCount == 0)
    }
}
