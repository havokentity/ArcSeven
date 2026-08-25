// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Shared furniture for the panes: the fixed pane size, the path-chooser row, footnotes.
//
// 7zFM's Options is a Windows property sheet, so every page is exactly the size of the
// sheet and switching tabs never moves the window. macOS settings windows do resize per
// pane, but doing that here would mean seven guessed heights and a window that jumps by
// two hundred points between Folders and File Types. One fixed size, with tall panes
// scrolling inside their form, is both closer to the original and calmer to use.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PaneMetrics {
    /// Wide enough for `Eliminate duplication of root folder` plus its control without wrapping.
    static let width: CGFloat = 620
    /// Tall enough for the Integration pane's twelve-row verb checklist without scrolling.
    static let height: CGFloat = 500
}

extension View {
    /// Apply the shared pane size. Every pane's root uses this and nothing else sets a frame.
    func settingsPaneFrame() -> some View {
        frame(width: PaneMetrics.width, height: PaneMetrics.height)
    }
}

/// Secondary explanatory text, sized and coloured once so seven panes agree.
struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a `PathChooserRow` is allowed to pick.
enum PathChoice {
    /// A folder, for the working-folder setting.
    case directory
    /// An application bundle or a Unix executable, for Viewer / Editor / Diff.
    ///
    /// Unix executables are allowed because 7zFM's Editor field takes any command line and
    /// people really do point Diff at `/usr/bin/opendiff` or a Homebrew binary; restricting
    /// the panel to `.applicationBundle` would make the field less capable than the original.
    case applicationOrExecutable
}

/// Label + path field + `…` browse button + clear button.
///
/// The row upstream is label, edit, `...`. The clear button is added because an *empty*
/// value is meaningful here (OPT-16, OPT-17) and there is otherwise no way back to it once a
/// path has been chosen — on Windows you select the text and press Delete, which is not a
/// discoverable affordance for a setting that changes which menu items exist.
struct PathChooserRow: View {
    let title: String
    let placeholder: String
    let choice: PathChoice
    /// Shown as the open panel's title. Upstream strings are reproduced verbatim where they
    /// exist — `Specify a location for temporary archive files.` is OPT-14's.
    let panelTitle: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", text: $path, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    // A `LabeledContent` trailing slot right-aligns its content, which puts a
                    // long path's *end* against the field's left edge and its start off-screen.
                    .multilineTextAlignment(.leading)
                    .frame(minWidth: 240)
                Button("…") { browse() }
                    .accessibilityLabel("Choose \(title)")
                Button {
                    path = ""
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(path.isEmpty)
                .accessibilityLabel("Clear \(title)")
            }
        }
    }

    @MainActor
    private func browse() {
        let panel = NSOpenPanel()
        panel.title = panelTitle
        panel.message = panelTitle
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false

        switch choice {
        case .directory:
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
        case .applicationOrExecutable:
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.application, .unixExecutable]
            panel.treatsFilePackagesAsDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }

        // A settings window is not document-modal to anything, so the panel is app-modal.
        // `runModal` keeps this synchronous, which is what makes the binding write below safe.
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
