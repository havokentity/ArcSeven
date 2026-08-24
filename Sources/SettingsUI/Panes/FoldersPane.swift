// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Options ▸ Folders, kept as-is.
//
// This is the one 7zFM Options page that needed no adaptation: it picks the folder in which
// a temporary archive is built while an update is in flight, and that concept is identical on
// both systems. Upstream's three radios, the path edit with its `...` button, the browse
// title and the `Use for removable drives only` checkbox all carry across verbatim
// (FIDELITY OPT-14).
//
// Why it matters more than it looks: adding a file to an archive rewrites the archive, and
// the rewrite happens in the working folder before the result is moved over the original. Put
// the working folder on the same volume as the archive and the move is a rename; put it
// elsewhere and every update copies the whole archive across volumes. That is what
// `Current` is for, and it is why the setting exists at all rather than always using $TMPDIR.

import SwiftUI

struct FoldersPane: View {

    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                // Stacked, as upstream stacks its three radios. A `Picker` left to itself in a
                // form row lays the radios out in a line and the last caption runs off the
                // right edge, which is how this looked before the VStack.
                // Captions are upstream's, and `Current` really is one word there — spelling it
                // `Current folder` costs forty points and pushes `Specified:` off the row,
                // because a radio group in a grouped form only keeps the mark beside its
                // caption while the three options still fit on one line.
                Picker("Working folder:", selection: $store.workDirType) {
                    Text("System temp folder").tag(WorkDirType.systemTemp)
                    Text("Current").tag(WorkDirType.currentFolder)
                    Text("Specified:").tag(WorkDirType.specified)
                }
                .pickerStyle(.radioGroup)

                PathChooserRow(
                    title: "Folder:",
                    placeholder: "No folder chosen",
                    choice: .directory,
                    // Upstream's browse caption, reproduced exactly.
                    panelTitle: "Specify a location for temporary archive files.",
                    path: $store.workDirPath
                )
                .disabled(store.workDirType != .specified)

                Toggle("Use for removable drives only", isOn: $store.tempRemovableOnly)
            } header: {
                Text("Temporary Files")
            } footer: {
                Footnote(
                    """
                    Updating an archive rebuilds it in the working folder and then moves the \
                    result over the original. Keeping the working folder on the same volume as \
                    the archive turns that move into a rename instead of a full copy, which is \
                    what “Current” is for. “Use for removable drives only” applies the \
                    choice just to archives on removable or ejectable volumes and leaves \
                    everything else in the system temp folder.
                    """
                )
            }

            Section("In Effect Now") {
                LabeledContent("Folder:") {
                    Text(effectiveDescription)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
    }

    /// What the current radio + path actually resolves to, so the pane is not the only place
    /// in the app where you cannot tell what a setting did.
    private var effectiveDescription: String {
        switch store.workDirType {
        case .systemTemp:
            NSTemporaryDirectory()
        case .currentFolder:
            "The folder containing the archive being updated"
        case .specified:
            store.workDirPath.isEmpty
                ? "Not set — falls back to \(NSTemporaryDirectory())"
                : store.workDirPath
        }
    }
}
