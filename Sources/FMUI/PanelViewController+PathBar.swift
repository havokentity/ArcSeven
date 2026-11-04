// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The path bar: the clickable crumb trail above the list.
//
// Split out of PanelViewController.swift for size; this is the same type. It is the cleanest
// seam in the class — it only reads the provider chain to draw crumbs and reports clicks
// back, and it declares no overrides, which an extension could not carry.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif

extension PanelViewController {
    // Internal, not private: the class body in PanelViewController.swift calls both of
    // these, and `private` is file-scoped.
    // MARK: Path bar

    func updatePathControl() {
        pathControl.url = nil
        pathControl.pathItems = pathComponents().map { component in
            let item = NSPathControlItem()
            item.title = component.title
            item.image = component.image
            return item
        }
    }

    /// Break the display path into clickable crumbs.
    ///
    /// Inside an archive the crumbs continue past the archive file itself, which is
    /// what makes `archive.7z/docs/img` read as one continuous path — 7zFM's model.
    private func pathComponents() -> [(title: String, image: NSImage?)] {
        let archiveIcon = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        // Copied before resizing. `NSWorkspace.icon(for:)` hands back a shared, cached
        // instance; resizing that in place resized the folder icon for every other
        // caller in the process — the list cells included, which copy theirs for
        // exactly this reason.
        let shared = NSWorkspace.shared.icon(for: .folder)
        let folderIcon = shared.copy() as? NSImage ?? shared
        folderIcon.size = NSSize(width: 16, height: 16)

        switch provider.kind {
        case .archive:
            guard let archive = provider as? ArchiveFolderProvider else { return [] }
            var crumbs: [(String, NSImage?)] = [(archive.archiveURL.lastPathComponent, archiveIcon)]
            if !archive.subPath.isEmpty {
                for component in archive.subPath.split(separator: "/") {
                    crumbs.append((String(component), folderIcon))
                }
            }
            return crumbs
        default:
            let path = provider.displayPath
            let components = path.split(separator: "/").map(String.init)
            return components.isEmpty
                ? [("/", folderIcon)]
                : components.map { ($0, folderIcon) }
        }
    }

    @objc func pathControlClicked(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(where: { $0 === clicked })
        else { return }
        let levelsUp = sender.pathItems.count - 1 - index
        guard levelsUp > 0 else { return }
        ascend(levels: levelsUp)
    }

    private func ascend(levels: Int) {
        Task { [weak self] in
            guard let self else { return }
            var target = provider
            for _ in 0..<levels {
                guard let parent = try? await target.parent() else { break }
                target = parent
            }
            go(to: target)
        }
    }
}
