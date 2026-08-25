// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Deep links into System Settings.
//
// Several 7zFM Options controls are *actions* on Windows — ticking a box writes the registry
// there and then. Their macOS counterparts are not ours to write: extension enablement and
// per-app language live in System Settings, and the honest replacement for the checkbox is a
// button that takes the user to the switch the OS owns.
//
// The pane identifiers are the bundle identifiers of the settings extensions in
// /System/Library/ExtensionKit/Extensions, which is why they are spelled out rather than
// guessed. They are *not* stable across releases: the Extensions pane was removed in macOS
// 15.0/15.1 and came back inside General ▸ Login Items & Extensions in 15.2 (see
// docs/DIVERGENCES.md D-11), which is exactly why this is one small versioned table instead
// of a URL scattered through the panes.

import AppKit

enum SystemSettingsLink {
    /// A pane worth linking to from settings.
    enum Pane {
        /// General ▸ Login Items & Extensions (macOS 15.2+), Privacy & Security ▸ Extensions before it.
        case extensions
        /// General ▸ Language & Region — where the per-app language override also lives.
        case languageAndRegion
    }

    /// Open a System Settings pane, or fall back to opening System Settings itself.
    @MainActor
    static func open(_ pane: Pane) {
        let identifier: String
        switch pane {
        case .extensions:
            // macOS 14 has no Login Items & Extensions; extensions are under Privacy & Security.
            if #available(macOS 15.0, *) {
                identifier = "com.apple.LoginItems-Settings.extension"
            } else {
                identifier = "com.apple.ExtensionsPreferences"
            }
        case .languageAndRegion:
            identifier = "com.apple.Localization-Settings.extension"
        }

        guard let url = URL(string: "x-apple.systempreferences:\(identifier)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Human-readable location of the extensions switch, for label text that must not lie
    /// about where the user is being sent.
    static var extensionsPaneName: String {
        if #available(macOS 15.0, *) {
            "General ▸ Login Items & Extensions"
        } else {
            "Privacy & Security ▸ Extensions"
        }
    }
}
