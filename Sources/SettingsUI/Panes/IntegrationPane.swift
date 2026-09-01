// SPDX-License-Identifier: Apache-2.0
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
// checklist, and Eliminate duplication of root folder. Dropped: the `(32-bit)` checkbox,
// which has no meaning anywhere on macOS, and the three `Compress and email` rows, which
// become one Share row.
//
// Also dropped, and for a different reason: upstream's `Propagate Zone.Id stream` combo
// (OPT-11, retargeted onto `com.apple.quarantine` by D-08). Its macOS equivalent is not a
// preference — see the Extraction section below.

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
                .disabled(true)

            NotYetApplied(
                """
                Nothing reads this switch. Whether ArcSeven’s commands appear in Finder is \
                decided entirely by the system setting reported below, and Services and Quick \
                Actions are registered from the app’s Info.plist whether it is on or off.
                """
            )

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
            Group {
                Toggle("Cascaded context menu", isOn: $store.cascadedMenu)
                Toggle("Icons in context menu", isOn: $store.menuIcons)
            }
            .disabled(true)

            NotYetApplied(menuPolicyNotice)
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
            Group {
                ForEach(ContextMenuVerb.allCases) { verb in
                    Toggle(verb.title, isOn: binding(for: verb))
                }
            }
            .disabled(true)

            NotYetApplied(menuPolicyNotice)
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

            // Upstream's three-way combo, deliberately not reproduced. It was here, bound to
            // `Options.WriteZone`, showing "No" — while extraction propagated unconditionally
            // and nothing read the key. Stating the behaviour is the honest control: there is
            // no choice to offer, and offering one would mean shipping upstream's "No".
            LabeledContent("Quarantine flag:") {
                Text(quarantineDescription)
                    .foregroundStyle(.secondary)
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
                onto everything extracted from it, so Gatekeeper still asks about a downloaded \
                application after it has been unpacked. 7-Zip makes this a choice and defaults \
                it off; ArcSeven does not, because switching it off would let anything inside a \
                downloaded archive launch with no Gatekeeper check at all.
                """
            )
        }
    }

    /// Read from the store rather than written in place, so the pane cannot drift from the
    /// behaviour the way it did when this was a picker.
    private var quarantineDescription: String {
        switch SettingsStore.quarantinePropagation {
        case .never: "Not propagated"
        case .always: "Always propagated"
        case .documentsAndExecutables: "Propagated for documents and executables"
        }
    }

    // MARK: Notices

    /// One sentence for both menu sections, because it is one missing read.
    ///
    /// `FinderSyncExtension.menu(for:)` builds a fixed menu and says so in its own header. It
    /// is a separate, sandboxed process, so honouring these means a shared-suite defaults read
    /// on Finder's UI thread — which is why it wants a snapshot refreshed by
    /// `arcSevenIntegrationDidChange`, the notification this window already posts to nobody.
    private let menuPolicyNotice = """
        The Finder extension builds a fixed menu. Honouring these means ArcSevenFinder \
        reading the shared defaults suite and observing arcSevenIntegrationDidChange, which \
        it does not do yet.
        """

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
