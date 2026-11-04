// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The seven toolbar operations of MainWindowController: Add, Extract, Test, Copy,
// Move, Delete, Info.
//
// Split out of MainWindowController.swift purely for size. The window's own concerns -
// construction, the toolbar, the panels, the progress sheet and the alert helpers -
// stay there; this file is the verbs those things invoke.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif
#if canImport(Dialogs)   // module-guard
import Dialogs
#endif
#if canImport(Support)   // module-guard
import Support
#endif
import os

private let quarantineLog = Logger(
    subsystem: "com.havokentity.ArcSeven", category: "quarantine"
)

/// The first file an extraction would overwrite, and whether it is the only one.
///
/// At file scope rather than nested in the controller so it is plainly free of the
/// controller's main-actor isolation: it is built on the pool and read on the main actor.
struct ExtractionConflictScan: Sendable {
    var existing: URL?
    var entry: ArchiveEntry?
    /// Counted, not just detected, because the count decides which answers are honest.
    /// Stops at two: the only question is "exactly one collision, or more than one", and
    /// a large archive over a large directory is a lot of stat calls to make for a
    /// number nobody reads.
    var count = 0
}

extension MainWindowController {
    // MARK: Operations

    /// Add to archive — 7zFM's Add button.
    ///
    /// Operates on the selection, or on everything in the folder when nothing is
    /// selected, which is what 7zFM does. Only meaningful for rows that exist on disk:
    /// re-compressing members of an archive in place is a later milestone.
    func addToArchive(from panel: PanelViewController) {
        guard let window else { return }

        let selected = panel.selectedItems.compactMap(\.url)
        let inputs: [URL]
        if !selected.isEmpty {
            inputs = selected
        } else if let directory = (panel.provider as? FileSystemFolderProvider)?.directoryURL {
            inputs = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        } else {
            inputs = []
        }

        guard !inputs.isEmpty else {
            presentMessage(
                "Nothing to add",
                "Select files on disk to compress. Adding to an archive from inside "
                    + "another archive is not supported yet."
            )
            return
        }

        // Default the archive name to the selection when it is a single item, or to
        // the enclosing folder otherwise — 7zFM's naming rule.
        let base = inputs.count == 1
            ? inputs[0].deletingPathExtension().lastPathComponent
            : inputs[0].deletingLastPathComponent().lastPathComponent
        let defaultURL = inputs[0]
            .deletingLastPathComponent()
            .appendingPathComponent(base.isEmpty ? "Archive" : base)
            .appendingPathExtension("7z")

        let dialog = CompressDialogController(defaultArchiveURL: defaultURL, inputs: inputs)
        dialog.present(in: window) { [weak self] request in
            guard let self, var request else { return }

            // Never feed the destination archive to itself.
            //
            // "Add" with nothing selected snapshots the whole folder, and if an archive
            // of the target name is already sitting there — which it is the second time
            // you press Add — it lands in the input set and gets packed into its own
            // replacement. Observed for real: a 41 KB src.7z reappeared as a member of
            // the 82 KB src.7z that replaced it. Upstream 7-Zip excludes the output
            // path from its inputs; so do we.
            let destination = request.archiveURL.standardizedFileURL
            request.inputs = request.inputs.filter { $0.standardizedFileURL != destination }

            guard !request.inputs.isEmpty else {
                presentMessage(
                    "Nothing to add",
                    "The only item selected was the archive being created."
                )
                return
            }

            run(
                operation: engine.compress(request),
                title: "Creating \(request.archiveURL.lastPathComponent)",
                completion: { result in
                    self.reportSuccess(
                        result,
                        title: "Archive created",
                        detail: request.archiveURL.path,
                        reveal: request.archiveURL
                    )
                    self.refreshPanelsShowing(request.archiveURL.deletingLastPathComponent())
                }
            )
        }
    }

    /// Extract — 7zFM's Extract button.
    func extractSelection(from panel: PanelViewController) {
        guard let window else { return }
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage(
                "Not an archive",
                "Open an archive first — Extract works on the contents of an archive."
            )
            return
        }

        let entries = panel.selectedItems.map(\.path)
        let dialog = ExtractDialogController(
            archiveURL: archive.archiveURL,
            selectedEntries: entries
        )
        dialog.present(in: window) { [weak self] request in
            guard let self, var request else { return }

            // "Ask before overwrite" cannot be answered mid-stream: the child process
            // has no interactive channel once it is running. Resolve conflicts up
            // front, then hand the engine a concrete, non-interactive mode.
            if request.overwriteMode == .ask {
                resolveOverwrite(for: request, in: archive.listing) { resolved in
                    guard let resolved else { return }
                    request = resolved
                    self.startExtraction(request, listing: archive.listing)
                }
            } else {
                startExtraction(request, listing: archive.listing)
            }
        }
    }

    /// Extract, asking first when the archive says it will expand to something alarming.
    ///
    /// The listing is already in hand at every call site, so the check is free. Pass `nil`
    /// only where no listing exists — the check is then skipped rather than guessed at.
    func startExtraction(_ request: ExtractRequest, listing: ArchiveListing?) {
        guard let listing else {
            startExtraction(request)
            return
        }
        let estimate = ExpansionPolicy.estimate(
            listing: listing,
            selectedEntries: request.selectedEntries,
            destination: request.destinationURL
        )
        guard estimate.warrantsConfirmation else {
            startExtraction(request)
            return
        }
        confirmExpansion(estimate, of: request.archiveURL) { [weak self] in
            self?.startExtraction(request)
        }
    }

    /// Ask, rather than refuse.
    ///
    /// Legitimate archives reach absurd ratios — a sparse disk image, a log of one repeated
    /// line, a tarball of zeros — so blocking them would be wrong. The dialog leads with the
    /// numbers so the decision can be an informed one.
    private func confirmExpansion(
        _ estimate: ExpansionEstimate,
        of archive: URL,
        proceed: @escaping @MainActor () -> Void
    ) {
        guard let window else { return }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        var reasons: [String] = []
        if estimate.exceedsAvailableSpace, let available = estimate.availableBytes {
            reasons.append(
                "That is more than the \(formatter.string(fromByteCount: Int64(available))) "
                    + "free on the destination volume."
            )
        }
        if estimate.exceedsRatioCeiling, let ratio = estimate.ratio {
            reasons.append(
                "It expands to about \(Int(ratio.rounded()))× the size of the archive, which "
                    + "is the shape of a decompression bomb."
            )
        }
        if estimate.exceedsAbsoluteCeiling {
            reasons.append("Extractions this large are unusual.")
        }
        if estimate.unsizedEntryCount > 0 {
            reasons.append(
                "\(estimate.unsizedEntryCount) member(s) declare no size, so the real total "
                    + "may be larger."
            )
        }

        let alert = NSAlert()
        alert.messageText = "\(archive.lastPathComponent) says it will expand to "
            + formatter.string(fromByteCount: Int64(min(estimate.declaredBytes, UInt64(Int64.max))))
        alert.informativeText = reasons.joined(separator: "\n\n")
            + "\n\nThese figures come from the archive's own header and cannot be trusted "
            + "further than the archive can."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Extract Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    /// Private on purpose: everything outside goes through `startExtraction(_:listing:)`,
    /// so the expansion check cannot be skipped by picking the shorter overload.
    private func startExtraction(_ request: ExtractRequest) {
        run(
            operation: engine.extract(request),
            title: "Extracting \(request.archiveURL.lastPathComponent)"
        ) { [weak self] result in
            // Off the main actor: propagation is two xattr calls per extracted item, and
            // for a hundred-thousand-file tree that was a visible stall between the
            // progress sheet closing and the completion alert opening. The alert waits
            // for it, so what it reports is still true when it is read.
            Task { [weak self] in
                await Task.detached(priority: .userInitiated) {
                    Self.propagateQuarantine(from: request)
                }.value
                self?.reportSuccess(
                    result,
                    title: "Extraction complete",
                    detail: "Extracted to \(request.destinationURL.path).",
                    reveal: request.destinationURL
                )
            }
        }
    }

    /// Carry `com.apple.quarantine` from the archive onto everything unpacked from it.
    ///
    /// An archive downloaded from the internet is quarantined; the files inside it are
    /// not, because the kernel never saw them arrive. Extracting without re-marking them
    /// hands the user a Gatekeeper bypass: a `.app` inside a downloaded `.zip` would
    /// launch with no prompt at all. `docs/SECURITY.md` §6 promises this behaviour, and
    /// until 0.1.1 the promise was false - `Quarantine.propagate` existed, was correct,
    /// and was never called from anywhere.
    ///
    /// Best-effort by design. A failure here must not turn a successful extraction into a
    /// user-visible error, but it is worth a log line, because the silent version of this
    /// is exactly the bug being fixed.
    nonisolated private static func propagateQuarantine(from request: ExtractRequest) {
        do {
            let marked = try Quarantine.propagate(
                from: request.archiveURL, toTreeAt: request.destinationURL
            )
            if marked > 0 {
                quarantineLog.debug("propagated to \(marked, privacy: .public) item(s)")
            }
        } catch {
            quarantineLog.error("propagation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Conflict pre-scan

    /// Every FILE the request will actually write.
    ///
    /// Two things this has to get right, both of which it previously got wrong and both
    /// of which cost users their data in 0.1.0:
    ///
    /// * A selected row can be a DIRECTORY. Skipping directory entries meant selecting a
    ///   folder and extracting it checked nothing at all — the members inside it were
    ///   never considered, so a full folder of existing files was overwritten in silence.
    ///   A selected directory now expands to every member beneath it.
    /// * An empty selection means "everything", which is already handled by falling back
    ///   to the whole listing.
    nonisolated static func filesAffected(
        by request: ExtractRequest,
        in listing: ArchiveListing
    ) -> [ArchiveEntry] {
        guard let selected = request.selectedEntries, !selected.isEmpty else {
            return listing.entries.filter { !$0.isDirectory }
        }
        let selectedSet = Set(selected)
        // A member is affected when it IS a selected path, or lives under a selected
        // directory. Compared with a trailing separator so that selecting "doc" does not
        // sweep in "docs/..." — a prefix test without it silently over-selects.
        let directoryPrefixes = selected.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return listing.entries.filter { entry in
            guard !entry.isDirectory else { return false }
            if selectedSet.contains(entry.path) { return true }
            return directoryPrefixes.contains { entry.path.hasPrefix($0) }
        }
    }

    /// Where `entry` will land on disk, under this request's PATH MODE.
    ///
    /// The mode is the whole point. `.noPaths` runs `7zz e`, which FLATTENS every member
    /// to its basename — so probing the full stored path looks for a file that cannot
    /// exist, finds no conflict, and lets the extraction proceed over the top of the
    /// user's data. Resolution still goes through the zip-slip guard rather than joining
    /// paths by hand.
    nonisolated static func extractionDestination(
        of entry: ArchiveEntry,
        under request: ExtractRequest
    ) -> URL? {
        let relative: String
        switch request.pathMode {
        case .noPaths:
            relative = (entry.path as NSString).lastPathComponent
        case .fullPaths, .currentPaths, .absolutePaths:
            relative = entry.path
        }
        guard !relative.isEmpty else { return nil }
        return try? PathSafety.resolvedDestination(
            root: request.destinationURL, entryPath: relative
        )
    }

    /// Ask about the first conflicting file, then apply the answer to the whole run.
    ///
    /// 7zFM prompts per file. The subprocess engine cannot, so ArcSeven asks once and
    /// maps the answer onto an `-ao*` switch. `docs/DIVERGENCES.md` records this; a
    /// true per-file prompt arrives with the in-process engine.
    private func resolveOverwrite(
        for request: ExtractRequest,
        in listing: ArchiveListing,
        completion: @escaping @MainActor (ExtractRequest?) -> Void
    ) {
        // The scan resolves every affected member through the zip-slip gate — a
        // `realpath` plus an `lstat` per path component — and then stats it. Over a
        // large archive that is seconds of syscalls, which used to run on the main
        // thread between the Extract sheet closing and anything else happening.
        Task { [weak self] in
            let scan = await Task.detached(priority: .userInitiated) {
                Self.scanForConflicts(request, in: listing)
            }.value
            guard let self else {
                completion(nil)
                return
            }
            askAboutConflict(scan, for: request, completion: completion)
        }
    }

    nonisolated static func scanForConflicts(
        _ request: ExtractRequest, in listing: ArchiveListing
    ) -> ExtractionConflictScan {
        let manager = FileManager.default
        var scan = ExtractionConflictScan()
        for entry in filesAffected(by: request, in: listing) {
            guard let destination = extractionDestination(of: entry, under: request) else { continue }
            if manager.fileExists(atPath: destination.path) {
                if scan.existing == nil {
                    scan.existing = destination
                    scan.entry = entry
                }
                scan.count += 1
                if scan.count > 1 { break }
            }
        }
        return scan
    }

    /// Put the one dialog up, or pass the request straight through when nothing collides.
    private func askAboutConflict(
        _ scan: ExtractionConflictScan,
        for request: ExtractRequest,
        completion: @escaping @MainActor (ExtractRequest?) -> Void
    ) {
        guard let existing = scan.existing, let entry = scan.entry, let window else {
            completion(request)
            return
        }
        let conflict = (existing: existing, entry: entry)
        let conflictCount = scan.count

        let attributes = try? FileManager.default.attributesOfItem(atPath: conflict.existing.path)
        let dialog = OverwriteDialogController(
            existing: FileInfo(
                path: conflict.existing.path,
                size: (attributes?[.size] as? NSNumber)?.uint64Value,
                modified: attributes?[.modificationDate] as? Date
            ),
            incoming: FileInfo(
                path: conflict.entry.path,
                size: conflict.entry.size,
                modified: conflict.entry.modified
            )
        )

        // One collision: `Yes` and `No` mean what they say, and there is nothing to apply
        // "to all", so the bulk answers go.
        //
        // More than one: the answer becomes a single `-ao*` for the whole run, so `Yes`
        // cannot mean "this file". Through 0.1.5 it was offered anyway and quietly
        // overwrote every collision — the sheet named one file and destroyed all of them.
        // Only the answers that describe the real behaviour are offered now.
        let isSingleConflict = conflictCount == 1
        dialog.showsExtraButtons = !isSingleConflict
        dialog.showsPerFileButtons = isSingleConflict
        // Return should not be the destructive answer.
        dialog.defaultsToNo = true

        dialog.present(in: window) { decision in
            var resolved = request
            switch decision {
            case .yes, .yesToAll: resolved.overwriteMode = .overwrite
            case .no, .noToAll:   resolved.overwriteMode = .skip
            case .autoRename:     resolved.overwriteMode = .autoRename
            case .cancel:         completion(nil); return
            }
            completion(resolved)
        }
    }

    /// Test — verify every member's CRC without writing anything.
    func testArchive(from panel: PanelViewController) {
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage("Not an archive", "Open an archive to test it.")
            return
        }
        let entries = panel.selectedItems.map(\.path)
        var request = TestRequest(archiveURL: archive.archiveURL)
        request.selectedEntries = entries.isEmpty ? nil : entries

        run(
            operation: engine.test(request),
            title: "Testing \(archive.archiveURL.lastPathComponent)"
        ) { [weak self] result in
            self?.reportSuccess(
                result,
                title: result.hasWarnings ? "Tested with warnings" : "No errors found",
                detail: "\(result.itemsProcessed) item(s) verified.",
                reveal: nil
            )
        }
    }

    /// Delete — Trash on disk, remove-from-archive inside one.
    func deleteSelection(from panel: PanelViewController) {
        let items = panel.selectedItems
        guard !items.isEmpty else {
            presentMessage("Nothing selected", "Select the items you want to delete.")
            return
        }

        if let archive = panel.provider as? ArchiveFolderProvider {
            confirmDestructive(
                "Delete \(items.count) item(s) from \(archive.archiveURL.lastPathComponent)?",
                "This rewrites the archive and cannot be undone."
            ) { [weak self] in
                guard let self else { return }
                let request = DeleteRequest(
                    archiveURL: archive.archiveURL,
                    entryPaths: items.map(\.path)
                )
                run(
                    operation: engine.delete(request),
                    title: "Updating \(archive.archiveURL.lastPathComponent)"
                ) { _ in
                    // The listing is now stale; reopen the archive at the same level.
                    self.reopenArchive(archive, in: panel)
                }
            }
            return
        }

        // On disk, Delete means "move to Trash" — the Mac meaning, and recoverable.
        //
        // Through the BATCH overload. The loop over the single-item `trash(_:)` that
        // stood here built its own failure strings out of `localizedDescription` and
        // threw the typed error away, so `TrashError.volumeHasNoTrash` — whose whole
        // documented contract is "the UI must offer the permanent delete instead and say
        // why" — arrived as an untyped sentence and offered nothing. On a network share
        // or a read-only disk image, Delete simply reported a failure the user had no
        // way to act on.
        let urls = items.compactMap(\.url)
        let summary = trashItems(urls)
        panel.reload()

        let outcome = Self.deleteOutcome(for: summary, attempted: urls.count)
        recordDeleteOutcome(outcome)
        switch outcome {
        case .silent:
            break
        case let .offerPermanentDelete(untrashable, alsoFailed):
            offerPermanentDelete(untrashable, alsoFailed: alsoFailed)
        case let .report(trashed, attempted, failures):
            presentMessage(
                "Moved \(trashed) of \(attempted) to the Trash",
                failures.prefix(5).joined(separator: "\n")
            )
        }
    }

    /// What a disk delete has to tell the user.
    ///
    /// Pure, so the decision can be asserted without an alert sheet in the way.
    enum DeleteOutcome: Equatable {
        /// Everything reached the Trash. Say nothing — this is the common case, and an
        /// alert confirming that Delete deleted things is noise.
        case silent

        /// Some items are on a volume with no Trash. There is nowhere to put them, so
        /// the only thing left to offer is the permanent delete, with the reason
        /// attached. `alsoFailed` carries any *other* failures in the same selection, so
        /// they are not lost behind this dialog.
        case offerPermanentDelete(items: [URL], alsoFailed: [String])

        /// Ordinary failures: no permission, already gone.
        case report(trashed: Int, attempted: Int, failures: [String])
    }

    /// Classify a batch outcome.
    ///
    /// The no-Trash case wins over the others when both are present: it is the only one
    /// with an action attached, and burying it in a list of sentences is what the old
    /// code did.
    static func deleteOutcome(for summary: TrashSummary, attempted: Int) -> DeleteOutcome {
        guard !summary.isCompleteSuccess else { return .silent }

        var untrashable: [URL] = []
        var others: [String] = []
        for failure in summary.failures {
            if case .volumeHasNoTrash = failure.error {
                untrashable.append(failure.source)
            } else {
                others.append(
                    "\(failure.source.lastPathComponent): "
                        + (failure.error.errorDescription ?? "could not be moved to the Trash.")
                )
            }
        }

        if !untrashable.isEmpty {
            return .offerPermanentDelete(items: untrashable, alsoFailed: others)
        }
        return .report(trashed: summary.trashed.count, attempted: attempted, failures: others)
    }

    /// The dialog `TrashError.volumeHasNoTrash` has always documented and never had.
    ///
    /// `.critical`, and Cancel is the default: this is the one delete in the app that
    /// cannot be undone, so Return must not perform it.
    private func offerPermanentDelete(_ urls: [URL], alsoFailed others: [String]) {
        guard let window, !urls.isEmpty else { return }

        let names = urls.map(\.lastPathComponent).prefix(5).joined(separator: "\n")
        var body = "The volume they are on has no Trash — network shares, read-only "
            + "volumes and some disk images do not have one — so there is nowhere to put "
            + "them back from. Deleting them removes them permanently.\n\n\(names)"
        if urls.count > 5 { body += "\n… and \(urls.count - 5) more" }
        if !others.isEmpty {
            body += "\n\nAlso not deleted:\n" + others.prefix(3).joined(separator: "\n")
        }

        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "\(urls[0].lastPathComponent) cannot be moved to the Trash"
            : "\(urls.count) items cannot be moved to the Trash"
        alert.informativeText = body
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Permanently")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.permanentlyDelete(urls)
        }
    }

    /// The only unlink in the app, and it is behind the confirmation above.
    private func permanentlyDelete(_ urls: [URL]) {
        Task { [weak self] in
            let failures = await Self.removeOffMain(urls)
            guard let self else { return }
            for panel in panels { panel.reload() }
            if !failures.isEmpty {
                presentMessage(
                    "Some items could not be deleted",
                    failures.prefix(5).joined(separator: "\n")
                )
            }
        }
    }

    /// Copy / Move — to the other panel when there is one, else to a chosen folder.
    ///
    /// This is 7zFM's F5/F6: with two panels open, the other panel IS the destination,
    /// which is the whole reason the two-pane layout exists.
    func transferSelection(from panel: PanelViewController, move: Bool) {
        let items = panel.selectedItems
        guard !items.isEmpty else {
            presentMessage("Nothing selected", "Select the items you want to \(move ? "move" : "copy").")
            return
        }

        // Extracting out of an archive is a copy by definition; a move would mean
        // deleting from the archive afterwards, which is a separate confirmation.
        if let archive = panel.provider as? ArchiveFolderProvider {
            guard let destination = otherPanelDirectory(besides: panel) else {
                presentMessage(
                    "No destination",
                    "Open a second panel (View ▸ Toggle Two Panels) on a folder, then "
                        + "Copy extracts the selection into it."
                )
                return
            }
            var request = ExtractRequest(archiveURL: archive.archiveURL, destinationURL: destination)
            request.selectedEntries = items.map(\.path)
            request.overwriteMode = .autoRename
            startExtraction(request, listing: archive.listing)
            return
        }

        guard let destination = otherPanelDirectory(besides: panel) else {
            presentMessage(
                "No destination",
                "Open a second panel (View ▸ Toggle Two Panels) to \(move ? "move" : "copy") into."
            )
            return
        }

        let sources = items.compactMap(\.url)
        Task { [weak self] in
            let failures = await Self.transferOffMain(sources, into: destination, move: move)
            guard let self else { return }
            for other in panels { other.reload() }
            if !failures.isEmpty {
                presentMessage("Some items could not be \(move ? "moved" : "copied")",
                               failures.prefix(5).joined(separator: "\n"))
            }
        }
    }

    private func otherPanelDirectory(besides panel: PanelViewController) -> URL? {
        for candidate in panels where candidate !== panel {
            if let directory = (candidate.provider as? FileSystemFolderProvider)?.directoryURL {
                return directory
            }
        }
        return nil
    }

    /// Info — the Properties inspector.
    ///
    /// One inspector per window, reused. Until 0.1.5 every press of ⌘I built a NEW
    /// controller; the previous one kept itself alive through its own `selfRetain` and
    /// stayed attached as a child window at the same origin, so two presses gave two
    /// stacked panels and nothing ever closed the one underneath. Reusing the instance
    /// also means the panel keeps the size and position the user gave it.
    func showInfo(for panel: PanelViewController) {
        guard let window else { return }
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage("No archive open", "Open an archive to see its properties.")
            return
        }

        let entry = panel.selectedItems.first?.entry
        if let existing = propertiesInspector {
            // Re-render before showing: a panel the user closed and reopened must not
            // come back describing whatever was selected when they closed it.
            existing.update(listing: archive.listing, entry: entry)
            existing.present(in: window)
            return
        }

        let inspector = PropertiesInspectorController(listing: archive.listing, entry: entry)
        inspector.present(in: window)
        propertiesInspector = inspector      // held so it is not deallocated while shown
    }

    /// Push the panel's current selection into the inspector, if one is open.
    ///
    /// The other half of the same defect: `update(listing:entry:)` existed, was correct,
    /// documented itself as the hook a panel owner calls on selection changes, and had
    /// ZERO call sites — so the panel showed a frozen snapshot of whatever was selected
    /// when ⌘I was pressed, while `docs/DIVERGENCES.md` D-27 and `docs/FIDELITY.md`
    /// PRP-01 both described it as following the selection live.
    ///
    /// Only archives have properties to inspect, so a panel that has left the archive
    /// leaves the panel showing the last archive rather than blanking it — closing it is
    /// the user's call, and an empty inspector answers no question.
    func refreshPropertiesInspector(from panel: PanelViewController) {
        guard let inspector = propertiesInspector else { return }
        guard let archive = panel.provider as? ArchiveFolderProvider else { return }
        inspector.update(listing: archive.listing, entry: panel.selectedItems.first?.entry)
    }
}
