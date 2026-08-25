// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Options ▸ Editor, kept.
//
// Three path fields, exactly as upstream: Viewer, Editor, Diff (FIDELITY OPT-15, stored as
// `FM.Viewer` / `FM.Editor` / `FM.Diff`, PST-11). Two deliberate differences, both of them
// improvements that cost no fidelity because the explicit path still wins when it is set:
//
//   * Empty Viewer. Windows fails the command with `Cannot start editor.`; here it falls
//     back to Quick Look, which is what a Mac user pressing the view key expects (OPT-16).
//   * Empty Editor falls back to the LaunchServices default for the file's type, i.e. what
//     double-clicking it in Finder would do.
//
// The Diff field is not decoration: setting it is what makes `File ▸ Diff` appear at all,
// upstream and here (OPT-17). Leaving it empty hides the command rather than showing a
// disabled one, which is why the footnote says so out loud.

import AppKit
import SwiftUI

struct EditorPane: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                PathChooserRow(
                    title: "View:",
                    placeholder: "Quick Look",
                    choice: .applicationOrExecutable,
                    panelTitle: "Choose the application to view files with.",
                    path: $store.viewerPath
                )
                resolvedRow(for: store.viewerPath)

                PathChooserRow(
                    title: "Editor:",
                    placeholder: "Default application for the file’s type",
                    choice: .applicationOrExecutable,
                    panelTitle: "Choose the application to edit files with.",
                    path: $store.editorPath
                )
                resolvedRow(for: store.editorPath)

                PathChooserRow(
                    title: "Diff:",
                    placeholder: "Not set — File ▸ Diff is hidden",
                    choice: .applicationOrExecutable,
                    panelTitle: "Choose the application to compare files with.",
                    path: $store.diffPath
                )
                resolvedRow(for: store.diffPath)
            } header: {
                Text("External Applications")
            } footer: {
                Footnote(
                    """
                    Leave View empty to use Quick Look, and Editor empty to use whichever \
                    application Finder would open the file with. Setting Diff is what makes \
                    File ▸ Diff appear in the menu; with no Diff application there is nothing \
                    for the command to do, so it is hidden rather than shown disabled. \
                    Files opened from inside an archive are extracted to a temporary copy \
                    first and written back when the application saves them.
                    """
                )
            }
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
    }

    /// A one-line confirmation of what a path resolves to.
    ///
    /// A settings field holding `/Applications/BBEdit.app` is unambiguous; one holding a path
    /// typed by hand into a text field, with a typo, looks identical until the command fails at
    /// the worst moment. This row says whether the file is there.
    @ViewBuilder
    private func resolvedRow(for path: String) -> some View {
        if !path.isEmpty {
            HStack(spacing: 6) {
                if let icon = icon(for: path) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(describe(path))
                    .font(.callout)
                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? .secondary : Color.red)
            }
        }
    }

    private func describe(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return "Not found: \(path)"
        }
        let url = URL(fileURLWithPath: path)
        // `displayName(atPath:)` keeps the `.app` suffix when the user has "show all filename
        // extensions" on, which is not how an application is named anywhere else in the UI.
        if url.pathExtension == "app" {
            let bundle = Bundle(url: url)
            let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary
            let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            return name ?? url.deletingPathExtension().lastPathComponent
        }
        return FileManager.default.displayName(atPath: path)
    }

    private func icon(for path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
