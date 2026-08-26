// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Options ▸ Settings, kept.
//
// Seven checkboxes and a memory ceiling. Every one of the seven means something on macOS —
// they are all about how the file list draws and behaves, not about Windows — so all seven
// survive, with their upstream captions and, more importantly, their upstream defaults:
// **every checkbox here is off**, which surprises people who expect ".." to be shown or the
// full row to be clickable. That is deliberate (FIDELITY OPT-18…OPT-24, DOT-01).
//
// The one drop is `Use large memory pages`, which needs `SeLockMemoryPrivilege` and has no
// macOS equivalent at all (DIVERGENCES D-12). It is not replaced by anything.
//
// Every control on this pane is currently disabled, and that is the honest state rather than
// a regression: nothing outside this window has ever read `FM.ShowDots` and the six keys
// beside it, and nothing emits `-mmemuse`. See `NotYetApplied` in SettingsPaneChrome.swift.

import SwiftUI

struct SettingsPane: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            fileListSection
            memorySection
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
    }

    // MARK: Sections

    private var fileListSection: some View {
        Section {
            // Disabled as a group rather than by disabling the Section, which would dim the
            // notice explaining the disabling along with them.
            Group {
                Toggle("Show “..” item", isOn: $store.showDots)
                Toggle("Show real file icons", isOn: $store.showRealFileIcons)
                Toggle("Full row select", isOn: $store.fullRow)
                Toggle("Show grid lines", isOn: $store.showGrid)
                Toggle("Single-click to open an item", isOn: $store.singleClick)
                Toggle("Alternative selection mode", isOn: $store.alternativeSelection)
                Toggle("Show Finder ▸ menu", isOn: $store.showSystemMenu)
            }
            .disabled(true)

            NotYetApplied(
                """
                The file list does not read these seven yet. FMUI’s panel view has to consult \
                them — and observe arcSevenListSettingsDidChange, which this window already \
                posts and nothing yet receives — before a switch here can change anything.
                """
            )
        } header: {
            Text("File List")
        } footer: {
            Footnote(
                """
                All seven are off by default, as in 7-Zip, and describe how the file list is \
                meant to draw and behave: “..” shown outside the root folder, whole-row \
                selection, grid lines, single-click open, and each file’s own icon instead of \
                one icon per file type. Alternative selection mode is the Norton-style scheme, \
                where marks are kept separately from the system selection. “Finder ▸” adds the \
                submenu with Reveal in Finder, Quick Look, Open With, Get Info and Tags.
                """
            )
        }
    }

    private var memorySection: some View {
        Section {
            Group {
                Toggle(isOn: $store.memUseEnabled) {
                    Text("Limit RAM used to unpack archives")
                }
                LabeledContent("Maximum:") {
                    HStack(spacing: 6) {
                        TextField(
                            "",
                            value: $store.memUseGigabytes,
                            format: .number.precision(.fractionLength(0))
                        )
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        Stepper("", value: $store.memUseGigabytes, in: 1...maximumSensibleGigabytes)
                            .labelsHidden()
                        Text("GB")
                    }
                }
            }
            .disabled(true)

            NotYetApplied(
                """
                Extraction runs with no ArcSeven-imposed ceiling today: nothing emits 7-Zip’s \
                -mmemuse switch, and the Memory usage request dialog this setting is supposed \
                to feed (MEM-01) does not exist, so there is nowhere to ask. A ceiling with no \
                dialog behind it would turn a large archive into a failure instead of a \
                question, which is worse than no ceiling.
                """
            )
        } header: {
            Text("Memory")
        } footer: {
            Footnote(
                "The ceiling 7-Zip applies to an unpack, and asks about before exceeding. "
                + "This Mac has \(physicalMemoryText) of RAM installed."
            )
        }
    }

    /// Physical RAM, rounded up, so the stepper cannot be pushed past what the machine has.
    /// A ceiling above installed RAM is not a limit, it is a lie.
    private var maximumSensibleGigabytes: Int {
        max(1, Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)))
    }

    private var physicalMemoryText: String {
        // Created per call rather than held in a static: a shared `ByteCountFormatter` is not
        // Sendable and would not survive strict concurrency. `FormatStyle` is a value type.
        Int64(ProcessInfo.processInfo.physicalMemory).formatted(.byteCount(style: .memory))
    }
}
