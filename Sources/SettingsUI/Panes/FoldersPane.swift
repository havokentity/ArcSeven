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
//
// Which is what makes it worth saying that the choice is not wired: `ArchiveInsertion` stages
// under `FileManager.temporaryDirectory` unconditionally, so "always using $TMPDIR" is exactly
// what happens. The controls are disabled and the "In Effect Now" row reports the real folder
// rather than the selected one; wiring them means emitting `-w` from FMKit.

import SwiftUI

struct FoldersPane: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            temporaryFilesSection
            effectiveSection
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
    }

    // MARK: Sections

    private var temporaryFilesSection: some View {
        Section {
            // Disabled as a group rather than by disabling the Section, which would dim the
            // notice explaining the disabling along with them.
            Group {
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

                Toggle("Use for removable drives only", isOn: $store.tempRemovableOnly)
            }
            .disabled(true)

            NotYetApplied(
                """
                Archive updates always stage in the system temp folder. FMKit’s \
                ArchiveInsertion builds its staging tree under \
                FileManager.temporaryDirectory and nothing emits 7-Zip’s -w switch, so none \
                of the three choices above would reach the engine.
                """
            )
        } header: {
            Text("Temporary Files")
        } footer: {
            Footnote(
                """
                Updating an archive rebuilds it in the working folder and then moves the \
                result over the original. Keeping the working folder on the same volume as \
                the archive turns that move into a rename instead of a full copy, which is \
                what “Current” is for. “Use for removable drives only” applies the choice \
                just to archives on removable or ejectable volumes and leaves everything \
                else in the system temp folder.
                """
            )
        }
    }

    private var effectiveSection: some View {
        Section("In Effect Now") {
            LabeledContent("Folder:") {
                Text(effectiveDirectory)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    /// The folder updates really stage in — not the folder the radios above would choose.
    ///
    /// This section used to render the *selection*, under a heading saying it was in effect,
    /// which made it the most confidently wrong thing in the window: it would tell you a
    /// working folder on the archive's own volume was live while every update was still
    /// copying across to $TMPDIR. `ArchiveInsertion.stage` is the one that decides, and it
    /// asks `FileManager` for this.
    private var effectiveDirectory: String {
        FileManager.default.temporaryDirectory.path
    }
}
