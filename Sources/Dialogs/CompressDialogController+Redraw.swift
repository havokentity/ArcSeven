// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Add to Archive: pushing the model back into the controls.
//
// One direction only — model to view. Programmatic changes to popups, checkboxes and text
// fields do not fire their actions, which is what lets every action handler in
// CompressDialogController+Actions.swift end with an unconditional `refresh()` without
// risking recursion.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

extension CompressDialogController {
    /// Repopulate a popup without letting `NSPopUpButton.addItem(withTitle:)` dedupe.
    ///
    /// That method removes an existing item with the same title, which would silently
    /// collapse two legitimately identical entries — and leave the index-to-value
    /// mapping the actions rely on off by one.
    private func apply(_ popup: NSPopUpButton, titles: [String], selectedIndex: Int, enabled: Bool) {
        let menu = NSMenu()
        if titles.isEmpty {
            // An empty popup renders as a bare chevron; a dash reads as "not applicable".
            menu.addItem(NSMenuItem(title: "—", action: nil, keyEquivalent: ""))
        } else {
            for title in titles {
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        popup.menu = menu
        popup.selectItem(at: min(max(selectedIndex, 0), menu.numberOfItems - 1))
        popup.isEnabled = enabled && !titles.isEmpty
    }

    // MARK: - Redraw

    /// Rebuild every control from the model.
    ///
    /// Programmatic changes to popups, checkboxes and text fields do not fire their
    /// actions, so this cannot recurse — which is what lets every action handler end
    /// with an unconditional `refresh()` and stop worrying about ordering.
    func refresh() {
        let availability = model.availability

        if archiveField.stringValue != model.archivePath {
            archiveField.stringValue = model.archivePath
        }

        refreshCompressionControls(availability)
        refreshFileSelectionControls(availability)
        refreshOptionControls(availability)
        refreshEncryptionControls(availability)
        refreshVolumeControls(availability)

        refreshMemory()
        refreshValidation()
    }

    /// The left column: everything that decides what the bytes end up looking like.
    private func refreshCompressionControls(_ availability: CompressDialogModel.Availability) {
        refreshCodecControls(availability)
        refreshSolidAndThreadControls(availability)
    }

    private func refreshCodecControls(_ availability: CompressDialogModel.Availability) {
        // Format.
        let formats = model.availableFormats
        apply(
            formatPopup,
            titles: formats.map { FormatCatalog.creatable($0)?.displayName ?? $0.rawValue },
            selectedIndex: formats.firstIndex(of: model.format) ?? 0,
            enabled: formats.count > 1
        )

        // Level.
        let levels = model.levelChoices
        apply(
            levelPopup,
            titles: levels.map(\.displayName),
            selectedIndex: levels.firstIndex(of: model.level) ?? 0,
            enabled: availability.levelEnabled
        )

        // Method. Index 0 carries the `*  ` prefix and means "emit nothing".
        let methods = model.methodChoices
        let methodTitles = methods.enumerated().map { index, method in
            index == 0 ? "*  " + method.rawValue : method.rawValue
        }
        let methodIndex = model.method.flatMap { methods.firstIndex(of: $0) } ?? 0
        apply(methodPopup, titles: methodTitles, selectedIndex: methodIndex, enabled: availability.methodEnabled)

        // Dictionary size.
        let dictionaries = model.dictionaryChoices
        var dictionaryTitles: [String] = []
        if !dictionaries.isEmpty {
            let auto = FormatCatalog.automaticDictionarySize(
                format: model.format, method: model.method, level: model.level)
            dictionaryTitles.append("*  " + (auto.map(CompressDialogModel.dictionaryLabel) ?? ""))
            dictionaryTitles.append(contentsOf: dictionaries.map(CompressDialogModel.dictionaryLabel))
        }
        let dictionaryIndex = model.dictionarySize.byteValue
            .flatMap { dictionaries.firstIndex(of: $0) }
            .map { $0 + 1 } ?? 0
        apply(
            dictionaryPopup,
            titles: dictionaryTitles,
            selectedIndex: dictionaryIndex,
            enabled: availability.dictionaryEnabled
        )

        // Word size — "fast bytes" for the LZ codecs, model order for PPMd (ADD-15).
        let words = model.wordSizeChoices
        var wordTitles: [String] = []
        if !words.isEmpty {
            let auto = FormatCatalog.automaticWordSize(
                format: model.format, method: model.method, level: model.level)
            wordTitles.append("*  " + (auto.map(String.init) ?? ""))
            wordTitles.append(contentsOf: words.map(String.init))
        }
        let wordIndex = model.wordSize.intValue.flatMap { words.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        apply(wordSizePopup, titles: wordTitles, selectedIndex: wordIndex, enabled: availability.wordSizeEnabled)
    }

    private func refreshSolidAndThreadControls(_ availability: CompressDialogModel.Availability) {
        // Solid block size.
        let solids = model.solidChoices
        apply(
            solidPopup,
            titles: solids.map(CompressDialogModel.solidLabel),
            selectedIndex: solids.firstIndex(of: model.solidBlockSize) ?? 0,
            enabled: availability.solidEnabled
        )

        // Threads.
        let threadChoices = model.threadChoices
        var threadTitles: [String] = []
        if !threadChoices.isEmpty {
            threadTitles.append("*  \(FormatCatalog.automaticThreads(format: model.format, method: model.method, hardwareThreads: model.hardwareThreads))")
            threadTitles.append(contentsOf: threadChoices.map(String.init))
        }
        let threadIndex = model.threads.intValue
            .flatMap { threadChoices.firstIndex(of: $0) }
            .map { $0 + 1 } ?? 0
        apply(threadsPopup, titles: threadTitles, selectedIndex: threadIndex, enabled: availability.threadsEnabled)
        threadsHint.stringValue = "/ \(model.hardwareThreads)"
    }

    private func refreshFileSelectionControls(_ availability: CompressDialogModel.Availability) {
        // Update and path mode.
        let updateModes = model.updateModeChoices
        apply(
            updateModePopup,
            titles: updateModes.map(\.displayName),
            selectedIndex: updateModes.firstIndex(of: model.updateMode) ?? 0,
            enabled: availability.updateModeEnabled
        )
        let pathModes = CompressPathMode.allCases
        apply(
            pathModePopup,
            titles: pathModes.map(\.displayName),
            selectedIndex: pathModes.firstIndex(of: model.pathMode) ?? 0,
            enabled: availability.pathModeEnabled
        )
    }

    private func refreshOptionControls(_ availability: CompressDialogModel.Availability) {
        // Options.
        sfxCheckbox.isEnabled = availability.selfExtractingEnabled
        sfxCheckbox.state = model.createSelfExtracting ? .on : .off
        sfxNote.isHidden = !(model.createSelfExtracting && model.selfExtractingModuleURL == nil)
        deleteCheckbox.state = model.deleteSourcesAfterCompression ? .on : .off

        symlinkCheckbox.isEnabled = availability.symbolicLinksEnabled
        symlinkCheckbox.state = model.storeSymbolicLinks ? .on : .off
        hardLinkCheckbox.isEnabled = availability.hardLinksEnabled
        hardLinkCheckbox.state = model.storeHardLinks ? .on : .off
        xattrCheckbox.isEnabled = availability.extendedAttributesEnabled
        xattrCheckbox.state = model.storeExtendedAttributes ? .on : .off
        posixCheckbox.isEnabled = availability.posixPermissionsEnabled
        posixCheckbox.state = model.storePOSIXPermissions ? .on : .off
    }

    private func refreshEncryptionControls(_ availability: CompressDialogModel.Availability) {
        // Encryption.
        let encryptionEnabled = availability.encryptionEnabled
        for control in [passwordSecureField, passwordPlainField, verifyField] as [NSTextField] {
            control.isEnabled = encryptionEnabled
        }
        showPasswordCheckbox.isEnabled = encryptionEnabled
        encryptionMethodPopup.isEnabled = encryptionEnabled
        encryptNamesCheckbox.isEnabled = encryptionEnabled

        if passwordSecureField.stringValue != model.password { passwordSecureField.stringValue = model.password }
        if passwordPlainField.stringValue != model.password { passwordPlainField.stringValue = model.password }
        if verifyField.stringValue != model.verifyPassword { verifyField.stringValue = model.verifyPassword }
        secureRow?.isHidden = model.showPassword
        plainRow?.isHidden = !model.showPassword
        showPasswordCheckbox.state = model.showPassword ? .on : .off
        verifyRow?.isHidden = model.showPassword

        let ciphers = model.descriptor?.encryptionMethods ?? []
        apply(
            encryptionMethodPopup,
            titles: ciphers.map(\.rawValue),
            selectedIndex: ciphers.firstIndex(of: model.encryptionMethod) ?? 0,
            // Enabled whenever the group is, even with a single cipher: 7z's list is
            // just AES-256, and greying it out would read as "unavailable" rather than
            // "there is nothing else to pick".
            enabled: encryptionEnabled
        )
        encryptNamesRow?.isHidden = !availability.encryptFileNamesShown
        encryptNamesCheckbox.state = model.encryptFileNames ? .on : .off
    }

    private func refreshVolumeControls(_ availability: CompressDialogModel.Availability) {
        // Volumes and parameters.
        volumeCombo.isEnabled = availability.volumesEnabled
        if volumeCombo.stringValue != model.volumeText { volumeCombo.stringValue = model.volumeText }
        if parametersField.stringValue != model.parametersText {
            parametersField.stringValue = model.parametersText
        }
    }

    private func refreshMemory() {
        let estimate = model.estimateMemory()
        let ram = ProcessInfo.processInfo.physicalMemory
        // 7-Zip shows `required / limit / RAM`; without a memory-limit control the
        // useful comparison is against the machine, so the RAM figure stays.
        compressMemoryLabel.stringValue =
            "\(CompressDialogModel.memoryLabel(estimate.compressing)) / \(CompressDialogModel.memoryLabel(ram))"
        decompressMemoryLabel.stringValue = CompressDialogModel.memoryLabel(estimate.decompressing)
    }

    func refreshValidation() {
        let volumeFailure = model.volumeSizeError
        volumeErrorLabel.stringValue = volumeFailure?.errorDescription ?? ""
        volumeErrorRow?.isHidden = volumeFailure == nil

        let passwordFailure = model.passwordError
        passwordErrorLabel.stringValue = passwordFailure?.errorDescription ?? ""
        passwordErrorRow?.isHidden = passwordFailure == nil

        // Unconditional rather than gated on EngineCapabilities: the dialog holds no
        // engine, and the CLI engine — the only one that exists — reports
        // `keepsPasswordsInProcess == false`. Gate this the day a second engine lands.
        let hasPassword = !model.password.isEmpty
        passwordExposureLabel.stringValue = hasPassword
            ? "While the archive is being created, the password is briefly visible to "
              + "other users signed in to this Mac."
            : ""
        passwordExposureRow?.isHidden = !hasPassword

        // Only the two conditions that can never produce a runnable command block OK.
        // Everything else 7-Zip validates on OK, and so do we — see `okPressed`.
        let pathEmpty = model.archivePath.trimmingCharacters(in: .whitespaces).isEmpty
        okButton.isEnabled = !pathEmpty && volumeFailure == nil

        resizeSheetToFit()
    }

    /// Track the content's height as rows come and go.
    ///
    /// Hiding the reenter field or an inline error changes how tall the dialog needs to
    /// be. Without this the sheet keeps whatever height it had at build time and the
    /// stack pads the difference out between its gravity areas — which shows up as an
    /// odd gap under the archive path when the encryption group shrinks.
    private func resizeSheetToFit() {
        guard let contentRoot else { return }
        contentRoot.layoutSubtreeIfNeeded()
        let wanted = contentRoot.fittingSize
        let current = sheet.contentLayoutRect.size
        guard abs(wanted.height - current.height) > 0.5 || abs(wanted.width - current.width) > 0.5 else {
            return
        }
        sheet.setContentSize(wanted)
    }
}
