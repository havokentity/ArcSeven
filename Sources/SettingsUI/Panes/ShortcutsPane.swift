// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Shortcuts — a tab 7zFM does not have, for a decision it never had to make.
//
// On Windows, F5 is Copy and Enter is Rename because that is what Norton Commander did in
// 1986 and every Windows file manager since has inherited it. On a Mac, Enter is Rename in
// Finder too — but F5 is nothing, ⌘C is Copy, and a file manager that made F5 the copy key
// and left ⌘C unbound would be wrong on both counts.
//
// docs/SHORTCUTS.md resolves this as a preset choice, and this pane is where the user makes
// it (FIDELITY PST-16, key `Shortcuts.Preset`). Two things about the design are worth knowing
// before reading the code:
//
//   * **Classic is additive.** It is the Finder preset with the Windows chords overlaid, not
//     a replacement table. Switching to it does not cost you ⌘C, ⌘I or ⌘⌫; it adds F5, F6,
//     F7, Insert, the numeric keypad and the Control-letter family on top. Only ⏎ and ␣
//     collide, and both resolve to the Windows meaning.
//   * **Every Classic chord is file-list scope.** They fire only when the file list has focus,
//     which is what makes bare ⌃-letter and bare ⌥-digit chords safe: switching presets can
//     never break typing in the path bar or the rename editor.
//
// Two Windows behaviours are deliberately not reproduced in either preset: ⌃W does not quit
// the application (7zFM posts IDCLOSE — one key from ⌘W, mid-extraction, is a data-loss bug),
// and RightCtrl+0…9 bookmarks are impossible in AppKit, which cannot distinguish the two
// Control keys in a key-equivalent.

import SwiftUI

struct ShortcutsPane: View {

    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(selection: $store.keymapPreset) {
                    ForEach(KeymapPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                } label: {
                    Text("Keyboard shortcuts:")
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Preset")
            } footer: {
                Footnote(presetExplanation)
            }

            Section("7-Zip Classic Adds") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Self.classicChords, id: \.chord) { row in
                        GridRow {
                            Text(row.chord)
                                .font(.body.monospaced())
                                .gridColumnAlignment(.leading)
                                .frame(minWidth: 64, alignment: .leading)
                            Text(row.command)
                            Text(row.note)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .opacity(store.keymapPreset == .finder ? 0.55 : 1)

                Footnote(
                    """
                    …plus the rest of the function-key row, ⌃F3–⌃F7 for sorting, ⌥0–⌥9 for the \
                    ten favourite folders, the numeric keypad’s select/deselect/invert family, \
                    and ⌃A ⌃C ⌃X ⌃V ⌃N ⌃R ⌃Z. All of them file-list scope only.
                    """
                )
            }

            Section("Custom Bindings") {
                LabeledContent("Overrides:") {
                    Text(store.customBindingCount == 0
                         ? "None recorded yet"
                         : "\(store.customBindingCount) changed")
                    .foregroundStyle(.secondary)
                }
                Button("Reset Custom Bindings…") {
                    store.resetCustomBindings()
                }
                .disabled(store.customBindingCount == 0)

                Footnote(
                    """
                    Custom starts as a copy of whichever preset is active when you first change \
                    a binding, and stores only the differences — so a shortcut you changed in \
                    this version still inherits every command added in the next one. Record a \
                    binding by selecting a command in the menu bar with this preset active. \
                    System shortcuts such as ⌘␣ and ⇧⌘3 cannot be bound in any preset.
                    """
                )
            }
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
    }

    private var presetExplanation: String {
        switch store.keymapPreset {
        case .finder:
            """
            The default. Where Finder has an opinion about a chord, Finder wins: ⌘O opens, \
            ⌘↑ goes to the enclosing folder, ⏎ renames, ␣ is Quick Look, ⌘⌫ moves to the Trash. \
            No function keys are bound at all.
            """
        case .commander:
            """
            Everything the Finder preset binds, plus 7-Zip’s Windows chords on top — for moving \
            between a PC at work and a Mac at home. The two chords that collide, ⏎ and ␣, take \
            the Windows meaning: ⏎ opens the selected item and ␣ marks it.
            """
        case .custom:
            """
            Your own bindings, layered over the preset that was active when you started \
            changing them. Everything you have not changed keeps following that preset.
            """
        }
    }

    // MARK: Reference table

    private struct ChordRow {
        let chord: String
        let command: String
        let note: String
    }

    /// The ten Classic chords worth showing in a settings pane, from docs/SHORTCUTS.md §5.
    /// The full table lives in that document; this is a decision aid, not documentation.
    private static let classicChords: [ChordRow] = [
        ChordRow(chord: "⏎", command: "Open", note: "instead of Rename"),
        ChordRow(chord: "␣", command: "Mark item", note: "instead of Quick Look"),
        ChordRow(chord: "F2", command: "Rename", note: ""),
        ChordRow(chord: "F3", command: "View", note: ""),
        ChordRow(chord: "F4", command: "Edit", note: ""),
        ChordRow(chord: "F5", command: "Copy", note: "to the other pane"),
        ChordRow(chord: "F6", command: "Move", note: "to the other pane"),
        ChordRow(chord: "F7", command: "New Folder", note: ""),
        ChordRow(chord: "F9", command: "Two panes", note: ""),
        ChordRow(chord: "Ins", command: "Mark and advance", note: ""),
        ChordRow(chord: "⌥F12", command: "Folders History", note: ""),
    ]
}
