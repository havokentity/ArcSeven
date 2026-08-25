// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Options ▸ 7-Zip becomes Integration.
//
// The Windows tab registers an in-process shell-extension DLL that `explorer.exe` loads into
// itself. There is no macOS counterpart to that, and there cannot be: the checkbox upstream
// is an *installer*, and the macOS equivalent switch belongs to the OS, not to us
// (docs/DIVERGENCES.md D-11, FIDELITY OPT-08…OPT-13).
//
// So this pane splits in two. The toggle here is ArcSeven's own policy — whether the app
// wants its Finder surfaces active — and it is ours to write. Whether macOS actually loads
// the extension is the user's decision in System Settings, so that is reported, not toggled,
// with a button that goes there. A checkbox that silently failed to enable anything would be
// worse than no checkbox.
//
// The rest of the tab survives intact because it is all policy rather than registration:
// cascaded vs inline (`setSubmenu(_:for:)`), icons (`NSMenuItem.image`), the per-verb
// checklist, Eliminate duplication of root folder, and Zone.Identifier propagation retargeted
// onto `com.apple.quarantine` (D-08). Dropped: the `(32-bit)` checkbox, which has no meaning
// anywhere on macOS, and the three `Compress and email` rows, which become one Share row.

import SwiftUI
#if canImport(FinderSync)
import FinderSync
#endif

struct IntegrationPane: View {
    @Bindable var store: SettingsStore

    /// What macOS reports about the Finder extension. Three states rather than two: before
    /// the first read, and on any build without FinderSync, the honest answer is "we do not
    /// know", and that must not render as "not enabled".
    private enum ExtensionStatus {
        case enabled
        case disabled
        case unknown
    }

    /// macOS's answer, not ours. Re-read on appear and on demand because the user can change
    /// it in System Settings while this window is open — which is the normal path, given the
    /// button below sends them there.
    @State private var extensionStatus: ExtensionStatus = .unknown

    var body: some View {
        Form {
            finderSection
            menuStyleSection
            contextMenuSection
            extractionSection
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
        .onAppear(perform: refreshExtensionStatus)
    }

    // MARK: Sections

    private var finderSection: some View {
        Section {
            Toggle("Enable Finder integration", isOn: $store.finderIntegration)

            LabeledContent("macOS reports:") {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(extensionStatus == .enabled ? Color.green : Color.secondary)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    Button("Refresh") { refreshExtensionStatus() }
                        .buttonStyle(.link)
                }
            }

            Button("Open \(SystemSettingsLink.extensionsPaneName)…") {
                SystemSettingsLink.open(.extensions)
            }
        } header: {
            Text("Finder")
        } footer: {
            Footnote(
                """
                ArcSeven adds its commands to Finder three ways at once: a Finder extension \
                for the context menu, a Services submenu, and Quick Actions that also appear \
                in Shortcuts and Spotlight. Only the first needs enabling, and only in \
                System Settings — macOS will not let an app switch its own extension on. \
                Services and Quick Actions work regardless. If the extension is enabled here \
                but absent in Finder, quitting and reopening ArcSeven re-registers it.
                """
            )
        }
    }

    private var menuStyleSection: some View {
        Section {
            Toggle("Cascaded context menu", isOn: $store.cascadedMenu)
            Toggle("Icons in context menu", isOn: $store.menuIcons)
        } header: {
            Text("Menu Style")
        } footer: {
            Footnote(
                "Cascaded puts every command under a single ArcSeven submenu; turning it off "
                + "puts the enabled commands directly in the context menu."
            )
        }
    }

    private var contextMenuSection: some View {
        Section {
            ForEach(ContextMenuVerb.allCases) { verb in
                Toggle(verb.title, isOn: binding(for: verb))
            }
        } header: {
            Text("Context Menu Items")
        } footer: {
            Footnote(
                """
                “<Folder>” and “<Archive>” are filled in from what is selected, by the same \
                naming rules 7-Zip uses. Share replaces 7-Zip’s three “Compress and email” \
                commands: the archive is built and handed to the system share sheet, which \
                reaches Mail and everything else.
                """
            )
        }
    }

    private var extractionSection: some View {
        Section {
            Toggle("Eliminate duplication of root folder", isOn: $store.elimDup)
            Picker("Propagate quarantine flag:", selection: $store.quarantinePropagation) {
                Text("No").tag(QuarantinePropagation.never)
                Text("Yes").tag(QuarantinePropagation.always)
                Text("For documents and executables").tag(QuarantinePropagation.documentsAndExecutables)
            }
        } header: {
            Text("Extraction")
        } footer: {
            Footnote(
                """
                Eliminate duplication of root folder is the same setting the Extract dialog \
                shows: when an archive contains exactly one top-level folder with the \
                archive’s own name, extracting to a new folder does not nest it twice. \
                Quarantine propagation copies the archive’s com.apple.quarantine attribute \
                onto the files extracted from it, so Gatekeeper still asks about a downloaded \
                application after it has been unpacked. It is off by default, as on Windows.
                """
            )
        }
    }

    // MARK: Verb checklist

    private func binding(for verb: ContextMenuVerb) -> Binding<Bool> {
        Binding(
            get: { store.isVerbEnabled(verb) },
            set: { store.setVerb(verb, enabled: $0) }
        )
    }

    // MARK: Extension status

    private var statusSymbol: String {
        switch extensionStatus {
        case .enabled: "checkmark.circle.fill"
        case .disabled: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusText: String {
        switch extensionStatus {
        case .enabled: "Finder extension enabled"
        case .disabled: "Finder extension not enabled"
        case .unknown: "Status unavailable"
        }
    }

    private func refreshExtensionStatus() {
        #if canImport(FinderSync)
        extensionStatus = FIFinderSyncController.isExtensionEnabled ? .enabled : .disabled
        #else
        extensionStatus = .unknown
        #endif
    }
}
