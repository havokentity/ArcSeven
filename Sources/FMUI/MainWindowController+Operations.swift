// SPDX-License-Identifier: GPL-3.0-or-later
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
                    self.startExtraction(request)
                }
            } else {
                startExtraction(request)
            }
        }
    }

    func startExtraction(_ request: ExtractRequest) {
        run(
            operation: engine.extract(request),
            title: "Extracting \(request.archiveURL.lastPathComponent)"
        ) { [weak self] result in
            self?.reportSuccess(
                result,
                title: "Extraction complete",
                detail: "Extracted to \(request.destinationURL.path).",
                reveal: request.destinationURL
            )
        }
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
        let candidates = request.selectedEntries ?? listing.entries.map(\.path)
        let manager = FileManager.default

        var conflict: (existing: URL, entry: ArchiveEntry)?
        for path in candidates {
            guard let entry = listing.entry(atPath: path), !entry.isDirectory else { continue }
            // Resolve through the zip-slip guard rather than joining paths naively.
            guard let destination = try? PathSafety.resolvedDestination(
                root: request.destinationURL, entryPath: path
            ) else { continue }
            if manager.fileExists(atPath: destination.path) {
                conflict = (destination, entry)
                break
            }
        }

        guard let conflict, let window else {
            completion(request)
            return
        }

        let attributes = try? manager.attributesOfItem(atPath: conflict.existing.path)
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
        let urls = items.compactMap(\.url)
        var trashed = 0
        var failures: [String] = []
        for url in urls {
            do { _ = try TrashService.trash(url); trashed += 1 } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        panel.reload()
        if !failures.isEmpty {
            presentMessage(
                "Moved \(trashed) of \(urls.count) to the Trash",
                failures.prefix(5).joined(separator: "\n")
            )
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
            startExtraction(request)
            return
        }

        guard let destination = otherPanelDirectory(besides: panel) else {
            presentMessage(
                "No destination",
                "Open a second panel (View ▸ Toggle Two Panels) to \(move ? "move" : "copy") into."
            )
            return
        }

        let manager = FileManager.default
        var failures: [String] = []
        for url in items.compactMap(\.url) {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            do {
                if move { try manager.moveItem(at: url, to: target) } else { try manager.copyItem(at: url, to: target) }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for other in panels { other.reload() }
        if !failures.isEmpty {
            presentMessage("Some items could not be \(move ? "moved" : "copied")",
                           failures.prefix(5).joined(separator: "\n"))
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
    func showInfo(for panel: PanelViewController) {
        guard let window else { return }
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage("No archive open", "Open an archive to see its properties.")
            return
        }
        let inspector = PropertiesInspectorController(
            listing: archive.listing,
            entry: panel.selectedItems.first?.entry
        )
        inspector.present(in: window)
        propertiesInspector = inspector      // held so it is not deallocated while shown
    }
}
