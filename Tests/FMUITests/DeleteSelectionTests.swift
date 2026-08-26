// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Delete, on disk.
//
// `TrashService` ships a batch API that carries on past failures and reports the whole
// selection as one `TrashSummary`, and a `TrashError.volumeHasNoTrash` case documented as
// "there is no way to trash an item there, so the UI must offer the permanent delete
// instead and say why". The caller used neither: it looped the single-item `trash(_:)`
// and rebuilt its own failure strings out of `localizedDescription`, discarding the typed
// error. On a network share or a read-only disk image, Delete reported a failure and
// offered nothing — the documented behaviour had no implementation.
//
// The trash operation is injected here. A test that proved this by moving the tester's
// files into their real Trash would be a worse test, not a better one.

import AppKit
import Foundation
import Testing
@testable import ArchiveCore
@testable import FMKit
@testable import FMUI
@testable import Support

@MainActor
@Suite("Delete selection")
final class DeleteSelectionTests {
    private let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenDeleteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["one.txt", "two.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeWindow() -> MainWindowController {
        MainWindowController(
            startingAt: root,
            engine: SevenZipCLIEngine(
                executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
            )
        )
    }

    private func waitForRows(in panel: PanelViewController) async {
        for _ in 0..<500 {
            if !panel.rows.isEmpty { return }
            await Task.yield()
        }
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// The temporary directory is `/var/folders/…`, a symlink to `/private/var/folders/…`,
    /// and `FileManager` hands the rows back spelled the second way. Comparing the two
    /// spellings as `URL`s fails, so both sides go through the same canonicalisation.
    private func canonical(_ urls: some Sequence<URL>) -> Set<String> {
        Set(urls.map { $0.resolvingSymlinksInPath().path })
    }

    // MARK: The batch call

    /// The wiring assertion: one call carrying the whole selection. The old loop went
    /// straight to `TrashService.trash(_:)` per item and would record no calls here at
    /// all, so either shape of the bug fails this.
    @Test("The whole selection goes to the Trash in one batch call")
    func deleteUsesTheBatchAPI() async throws {
        let controller = makeWindow()
        let panel = controller.panels[0]
        await waitForRows(in: panel)

        nonisolated(unsafe) var batches: [[URL]] = []
        controller.trashItems = { urls in
            batches.append(urls)
            return TrashSummary(
                trashed: urls.map { TrashOutcome(source: $0, trashedURL: nil) }, failures: []
            )
        }

        panel.selectRows(IndexSet(panel.rows.indices))
        controller.deleteSelection(from: panel)

        #expect(batches.count == 1, "the selection was not trashed as one batch")
        #expect(canonical(batches.first ?? []) == canonical([url("one.txt"), url("two.txt")]))
        #expect(controller.lastDeleteOutcome == .silent, "a clean delete should say nothing")
    }

    @Test("Nothing selected trashes nothing")
    func emptySelectionDoesNothing() async {
        let controller = makeWindow()
        let panel = controller.panels[0]
        await waitForRows(in: panel)

        nonisolated(unsafe) var called = false
        controller.trashItems = { _ in
            called = true
            return TrashSummary(trashed: [], failures: [])
        }

        panel.selectRows(IndexSet())
        controller.deleteSelection(from: panel)
        #expect(!called)
    }

    // MARK: The no-Trash volume

    /// The documented behaviour that had no implementation.
    @Test("A volume with no Trash leads to the permanent-delete offer")
    func noTrashVolumeOffersPermanentDelete() async throws {
        let controller = makeWindow()
        let panel = controller.panels[0]
        await waitForRows(in: panel)

        controller.trashItems = { urls in
            TrashSummary(
                trashed: [],
                failures: urls.map {
                    TrashFailure(source: $0, error: .volumeHasNoTrash(path: $0.path))
                }
            )
        }

        panel.selectRows(IndexSet(panel.rows.indices))
        controller.deleteSelection(from: panel)

        let outcome = try #require(controller.lastDeleteOutcome)
        guard case let .offerPermanentDelete(items, alsoFailed) = outcome else {
            Issue.record("expected the permanent-delete offer, got \(outcome)")
            return
        }
        #expect(canonical(items) == canonical([url("one.txt"), url("two.txt")]))
        #expect(alsoFailed.isEmpty)
    }

    // MARK: Classification

    private func summary(
        trashed: [URL] = [], failures: [(URL, TrashError)] = []
    ) -> TrashSummary {
        TrashSummary(
            trashed: trashed.map { TrashOutcome(source: $0, trashedURL: nil) },
            failures: failures.map { TrashFailure(source: $0.0, error: $0.1) }
        )
    }

    @Test("A complete success says nothing")
    func successIsSilent() {
        let outcome = MainWindowController.deleteOutcome(
            for: summary(trashed: [url("one.txt")]), attempted: 1
        )
        #expect(outcome == .silent)
    }

    @Test("Ordinary failures are reported, with counts")
    func ordinaryFailuresAreReported() {
        let outcome = MainWindowController.deleteOutcome(
            for: summary(
                trashed: [url("one.txt")],
                failures: [(url("two.txt"), .notPermitted(path: url("two.txt").path))]
            ),
            attempted: 2
        )
        guard case let .report(trashed, attempted, failures) = outcome else {
            Issue.record("expected a plain report, got \(outcome)")
            return
        }
        #expect(trashed == 1)
        #expect(attempted == 2)
        #expect(failures.count == 1)
        #expect(failures[0].contains("two.txt"))
        #expect(failures[0].contains("permission"), "the typed error's own wording is used")
    }

    /// The no-Trash case wins when both are present: it is the only one with an action
    /// attached, and burying it in a list of sentences is what the old code did. The
    /// other failures still travel with it rather than being dropped.
    @Test("A no-Trash failure outranks an ordinary one, and carries it along")
    func noTrashOutranksOtherFailures() {
        let outcome = MainWindowController.deleteOutcome(
            for: summary(
                failures: [
                    (url("one.txt"), .notPermitted(path: url("one.txt").path)),
                    (url("two.txt"), .volumeHasNoTrash(path: url("two.txt").path)),
                ]
            ),
            attempted: 2
        )
        guard case let .offerPermanentDelete(items, alsoFailed) = outcome else {
            Issue.record("expected the permanent-delete offer, got \(outcome)")
            return
        }
        #expect(items == [url("two.txt")], "only the untrashable item may be offered")
        #expect(alsoFailed.count == 1)
        #expect(alsoFailed[0].contains("one.txt"), "the other failure was dropped")
    }
}
