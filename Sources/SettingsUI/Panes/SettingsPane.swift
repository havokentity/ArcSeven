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

import SwiftUI

struct SettingsPane: View {

    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Show “..” item", isOn: $store.showDots)
                Toggle("Show real file icons", isOn: $store.showRealFileIcons)
                Toggle("Full row select", isOn: $store.fullRow)
                Toggle("Show grid lines", isOn: $store.showGrid)
                Toggle("Single-click to open an item", isOn: $store.singleClick)
                Toggle("Alternative selection mode", isOn: $store.alternativeSelection)
                Toggle("Show Finder ▸ menu", isOn: $store.showSystemMenu)
            } header: {
                Text("File List")
            } footer: {
                Footnote(
                    """
                    All seven are off by default, as in 7-Zip. “..” is never shown in the root \
                    folder even when it is on. Alternative selection mode is the Norton-style \
                    scheme: marks are kept separately from the system selection. Real file icons \
                    read each file’s own icon instead of one icon per file type, which costs a \
                    stat per row. “Finder ▸” adds the submenu with Reveal in Finder, Quick Look, \
                    Open With, Get Info and Tags.
                    """
                )
            }

            Section {
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
                .disabled(!store.memUseEnabled)
            } header: {
                Text("Memory")
            } footer: {
                Footnote(
                    """
                    A job that would need more than this asks first, in the same \
                    Memory usage request dialog 7-Zip shows. This Mac has \(physicalMemoryText) \
                    of RAM installed.
                    """
                )
            }
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
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
