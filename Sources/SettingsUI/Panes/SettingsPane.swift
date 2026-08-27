// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Options ▸ Settings, kept.
//
// Six checkboxes and a memory ceiling, with their upstream captions and, more importantly,
// their upstream defaults: **every checkbox here is off**, which surprises people who expect
// ".." to be shown. That is deliberate (FIDELITY OPT-18…OPT-24, DOT-01).
//
// Five of the six are live: FMUI's `PanelListSettings` reads their keys straight off the
// standard domain and the panel observes `arcSevenListSettingsDidChange`, so moving one here
// redraws every open panel. `Show Finder ▸ menu` is the one that still stores and does
// nothing, because the submenu it governs (MF-25) does not exist yet, so it keeps its notice.
//
// Two drops. `Use large memory pages` needs `SeLockMemoryPrivilege` and has no macOS
// equivalent (DIVERGENCES D-12). `Full row select` (OPT-20) has no macOS equivalent either
// for the opposite reason — `NSTableView` is always full-row, so the checkbox had no second
// position to offer (DIVERGENCES D-29). Neither is replaced by anything.

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
            Toggle("Show “..” item", isOn: $store.showDots)
            Toggle("Show real file icons", isOn: $store.showRealFileIcons)
            Toggle("Show grid lines", isOn: $store.showGrid)
            Toggle("Single-click to open an item", isOn: $store.singleClick)
            Toggle("Alternative selection mode", isOn: $store.alternativeSelection)

            // Still stored and still unread, so it keeps the notice the other five lost.
            Toggle("Show Finder ▸ menu", isOn: $store.showSystemMenu)
                .disabled(true)
            NotYetApplied(
                """
                The Finder ▸ submenu this switch governs does not exist yet, so there is \
                nothing for it to show or hide. The five switches above it are live.
                """
            )
        } header: {
            Text("File List")
        } footer: {
            Footnote(
                """
                All six are off by default, as in 7-Zip, and describe how the file list draws \
                and behaves: “..” shown outside the root folder, grid lines, single-click \
                open, and each file’s own icon instead of one icon per file type. \
                Alternative selection mode is the Norton-style scheme, where marks are kept \
                separately from the system selection: Edit ▸ Mark Item (⌃Space) marks the \
                focused row and moves down, and marks are what Extract, Test and Delete then \
                act on. “Finder ▸” \
                adds the submenu with Reveal in Finder, Quick Look, Open With, Get Info and \
                Tags.
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
