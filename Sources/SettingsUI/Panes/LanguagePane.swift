// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Options ▸ Language, kept — but honest about how macOS actually picks a language.
//
// 7-Zip ships ~90 `Lang/*.txt` files and its combo box is the only way to switch between
// them, because Windows applications choose their own UI language. macOS does not work that
// way: the OS hands every app an ordered list of preferred languages, the app picks the best
// `.lproj` it has, and the user overrides it per-app in System Settings ▸ General ▸
// Language & Region ▸ Applications. An app-private language menu that ignored that would be
// a second, competing setting for the same thing.
//
// So the tab stays, in the same position, with the same two controls (FIDELITY OPT-27,
// OPT-28, DIVERGENCES D-26), and the picker writes the *system* override — `AppleLanguages`
// in the app's own defaults domain, which is the same key System Settings writes — alongside
// the ledger's `Lang` key. Choosing "System Language" removes the override rather than
// writing an empty one.
//
// At v1.0 the list has one entry. That is scheduling, not a decision against localisation:
// the string catalogs are wired, and adding a language adds a row here.

import SwiftUI

struct LanguagePane: View {
    @Bindable var store: SettingsStore

    /// Set when the user changes the picker, because the change cannot take effect until the
    /// next launch and saying so only after a real edit avoids a permanent scolding banner.
    @State private var didChange = false

    var body: some View {
        Form {
            Section {
                Picker("Language:", selection: $store.language) {
                    Text("System Language").tag("")
                    Divider()
                    ForEach(availableLanguages, id: \.code) { language in
                        Text(language.title).tag(language.code)
                    }
                }
                .onChange(of: store.language) { didChange = true }

                if didChange {
                    Label(
                        "Quit and reopen ArcSeven for the language change to take effect.",
                        systemImage: "arrow.clockwise"
                    )
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Language")
            } footer: {
                Footnote(
                    """
                    ArcSeven follows the system language by default. Choosing a language here \
                    writes the same per-app override that System Settings ▸ General ▸ \
                    Language & Region ▸ Applications writes, so the two agree instead of \
                    competing. Menu titles are also how macOS identifies items for custom \
                    keyboard shortcuts, which is why a language change is applied at launch \
                    rather than under a live window.
                    """
                )
            }

            Section("Translation") {
                // A whole sentence does not belong in a `LabeledContent` trailing slot: it
                // wraps under its own label and reads as a stray paragraph.
                Footnote(statusText)
                LabeledContent("In use now:") {
                    Text(effectiveLanguageTitle)
                        .foregroundStyle(.secondary)
                }
                Button("Open Language & Region…") {
                    SystemSettingsLink.open(.languageAndRegion)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
    }

    // MARK: Available languages

    private struct Language {
        let code: String
        let title: String
    }

    /// Populated from the bundle's own localisations, so the list cannot claim a language the
    /// app does not actually contain. Upstream reads its `Lang` folder for the same reason.
    private var availableLanguages: [Language] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .map { Language(code: $0, title: Self.title(for: $0)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `English`, or `German (Deutsch)` — upstream's rule: English name alone when the two
    /// names match, English name plus native name when they differ (OPT-27).
    private static func title(for code: String) -> String {
        let english = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        let native = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return english.caseInsensitiveCompare(native) == .orderedSame ? english : "\(english) (\(native))"
    }

    private var effectiveLanguageTitle: String {
        guard let code = Bundle.main.preferredLocalizations.first else { return "Unknown" }
        return Self.title(for: code)
    }

    private var statusText: String {
        let count = Bundle.main.localizations.filter { $0 != "Base" }.count
        if count <= 1 {
            return "English only. ArcSeven’s interface is not yet translated; contributions are welcome."
        }
        return "\(count) languages available."
    }
}
