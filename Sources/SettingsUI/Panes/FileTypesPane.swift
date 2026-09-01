// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Options ▸ System becomes File Types.
//
// The Windows tab writes file-association keys into the registry, with a current-user column,
// an all-users column and an admin-rights prompt. None of that exists here. On macOS the
// database of "which app opens which kind of file" is LaunchServices', it is strictly
// per-user, there is no supported system-wide API, and — checked on macOS 26 — there is no
// System Settings pane for it either: the only system-provided UI is Finder's
// Get Info ▸ Open with ▸ Change All, one file type at a time.
//
// So the tab keeps its shape and changes its mechanism (docs/DIVERGENCES.md D-06,
// FIDELITY OPT-03…OPT-07). The list is the same list; each row shows the same four states
// upstream shows — blank, another application's name, `[ArcSeven]` for a *different* copy of
// this app, and `ArcSeven` for this one — and the buttons write through
// `NSWorkspace.setDefaultApplication(at:toOpen:)` instead of `RegSetValueEx`. The all-users
// column is gone, because it could never be filled in.
//
// The list is derived from the app's own `CFBundleDocumentTypes`, never hard-coded, so the
// pane cannot drift from what the bundle actually claims (OPT-07). Outside an app bundle —
// a `swift run` during development — it falls back to the format catalogue, which is the
// same source the Info.plist was generated from.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
import SwiftUI
import UniformTypeIdentifiers

struct FileTypesPane: View {
    @State private var model = FileTypesModel()

    var body: some View {
        Form {
            Section {
                ForEach(model.rows) { row in
                    FileTypeRow(row: row) { model.makeDefault(row) }
                }
            } header: {
                Text("Archive Types ArcSeven Opens")
            } footer: {
                Footnote(
                    """
                    macOS decides which application opens a file type, per user, through \
                    LaunchServices — there is no equivalent of Windows’ per-extension registry \
                    list, and no System Settings pane for it. The buttons above are the same \
                    change Finder makes from Get Info ▸ Open with ▸ Change All. ArcSeven claims \
                    every type as an alternate handler, never as the default, so installing it \
                    does not quietly take file types away from Archive Utility.
                    """
                )
            }

            Section {
                HStack {
                    Button("Make ArcSeven the Default for All Listed Types") {
                        model.makeDefaultForAll()
                    }
                    .disabled(model.rows.isEmpty)
                    Spacer()
                    Button("Refresh") { model.reload() }
                }
                if let failure = model.lastFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneFrame()
        .onAppear { model.reload() }
    }
}

// MARK: - Row

private struct FileTypeRow: View {
    let row: FileTypesModel.Row
    let setDefault: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(row.handler.displayText)
                .font(.callout)
                .foregroundStyle(row.handler.isThisApp ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Set Default", action: setDefault)
                .disabled(row.handler.isThisApp || row.contentType == nil)
        }
    }
}

// MARK: - Model

/// The LaunchServices side of the pane, kept out of the view because it does I/O and has to
/// survive being asked the same question every time the window is brought forward.
@MainActor
@Observable
final class FileTypesModel {
    /// The four states 7zFM's association cells show, mapped onto LaunchServices.
    enum HandlerState: Equatable {
        /// Nothing claims the type. Upstream renders this as an empty cell.
        case unclaimed
        /// Another application. Upstream shows its name.
        case other(String)
        /// A *different* copy of this app — same bundle identifier, different location.
        /// Upstream's `[7-Zip]`, and a real situation: an app in ~/Downloads and one in
        /// /Applications look identical in every list until one of them is the handler.
        case otherCopy
        /// This bundle.
        case thisApp

        var displayText: String {
            switch self {
            case .unclaimed: "—"
            case .other(let name): name
            case .otherCopy: "[ArcSeven]"
            case .thisApp: "ArcSeven"
            }
        }

        var isThisApp: Bool { self == .thisApp }
    }

    struct Row: Identifiable {
        let id: String
        let name: String
        let contentType: UTType?
        let filenameExtensions: [String]
        /// `CFBundleTypeRole` — Editor for the seven formats `7zz` can write, Viewer for the
        /// rest. RAR is permanently Viewer: the unRAR licence forbids writing a RAR compressor.
        let canWrite: Bool
        var handler: HandlerState

        var subtitle: String {
            let extensions = filenameExtensions.prefix(6).map { ".\($0)" }.joined(separator: " ")
            let role = canWrite ? "read & write" : "read only"
            return extensions.isEmpty ? role : "\(extensions) · \(role)"
        }
    }

    private(set) var rows: [Row] = []
    private(set) var lastFailure: String?

    // MARK: Loading

    func reload() {
        let declarations = Self.declaredTypes()
        rows = declarations.map { declaration in
            Row(
                id: declaration.id,
                name: declaration.name,
                contentType: declaration.contentType,
                filenameExtensions: declaration.filenameExtensions,
                canWrite: declaration.canWrite,
                handler: Self.handlerState(for: declaration.contentType)
            )
        }
    }

    // MARK: Writing

    func makeDefault(_ row: Row) {
        guard let type = row.contentType else { return }
        apply(to: [type])
    }

    func makeDefaultForAll() {
        apply(to: rows.compactMap(\.contentType))
    }

    /// Claim one or more content types.
    ///
    /// `setDefaultApplication` is asynchronous and reports per-type failures, which do happen:
    /// a type declared by no installed app at all cannot be claimed. Failures are collected
    /// rather than thrown, because a bulk claim over thirty types must not stop at the first
    /// one the system refuses.
    private func apply(to types: [UTType]) {
        let appURL = Bundle.main.bundleURL
        lastFailure = nil
        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.lastFailure = "\(type.identifier): \(error.localizedDescription)"
                    }
                    self.reload()
                }
            }
        }
    }

    // MARK: LaunchServices

    private static func handlerState(for type: UTType?) -> HandlerState {
        guard let type, let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            return .unclaimed
        }
        let ourBundle = Bundle.main
        if handler.standardizedFileURL == ourBundle.bundleURL.standardizedFileURL {
            return .thisApp
        }
        if let identifier = Bundle(url: handler)?.bundleIdentifier,
           identifier == ourBundle.bundleIdentifier {
            return .otherCopy
        }
        return .other(displayName(of: handler))
    }

    private static func displayName(of applicationURL: URL) -> String {
        let bundle = Bundle(url: applicationURL)
        let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String {
            return name
        }
        return applicationURL.deletingPathExtension().lastPathComponent
    }

    // MARK: The declared list

    private struct Declaration {
        let id: String
        let name: String
        let contentType: UTType?
        let filenameExtensions: [String]
        let canWrite: Bool
    }

    /// `CFBundleDocumentTypes`, in Info.plist order, which is the order the plist lists them:
    /// system-declared types first, then the ones ArcSeven imports.
    private static func declaredTypes() -> [Declaration] {
        guard let entries = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]],
              !entries.isEmpty else {
            return catalogueFallback()
        }

        var seen = Set<String>()
        var result: [Declaration] = []
        for entry in entries {
            let name = entry["CFBundleTypeName"] as? String ?? "Archive"
            let canWrite = (entry["CFBundleTypeRole"] as? String) == "Editor"
            let identifiers = entry["LSItemContentTypes"] as? [String] ?? []
            // One row per declared UTI rather than per plist entry: a row whose button claims
            // only the first of three types would be a lie the second time you looked at it.
            for identifier in identifiers where seen.insert(identifier).inserted {
                let type = UTType(identifier)
                result.append(
                    Declaration(
                        id: identifier,
                        name: identifiers.count > 1 ? "\(name) (\(shortName(of: identifier)))" : name,
                        contentType: type,
                        filenameExtensions: type?.tags[.filenameExtension] ?? [],
                        canWrite: canWrite
                    )
                )
            }
        }
        return result
    }

    /// The trailing component of a UTI, for disambiguating two rows built from one plist entry
    /// — `public.tar-bzip2-archive` reads as `tar-bzip2-archive`.
    private static func shortName(of identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    /// Used when there is no Info.plist to read, i.e. a development build run straight from
    /// SwiftPM. The catalogue is where the plist's list came from in the first place, so the
    /// two agree; this is not a second source of truth.
    private static func catalogueFallback() -> [Declaration] {
        var seen = Set<String>()
        var result: [Declaration] = []

        for format in FormatCatalog.creatableFormats {
            guard let creatable = FormatCatalog.creatable(format) else { continue }
            append(
                name: creatable.displayName,
                extensions: creatable.extensions,
                canWrite: true,
                into: &result,
                seen: &seen
            )
        }
        for format in FormatCatalog.extractOnlyFormats {
            append(
                name: format.format.rawValue,
                extensions: format.extensions,
                canWrite: false,
                into: &result,
                seen: &seen
            )
        }
        return result
    }

    private static func append(
        name: String,
        extensions: [String],
        canWrite: Bool,
        into result: inout [Declaration],
        seen: inout Set<String>
    ) {
        // Resolve through the extension because the fallback has no UTIs of its own; an
        // extension macOS does not know (`.cramfs`, say) yields no row rather than a fake one.
        guard let first = extensions.first,
              let type = UTType(filenameExtension: first),
              !type.isDynamic,
              seen.insert(type.identifier).inserted else { return }
        result.append(
            Declaration(
                id: type.identifier,
                name: name,
                contentType: type,
                filenameExtensions: extensions,
                canWrite: canWrite
            )
        )
    }
}
