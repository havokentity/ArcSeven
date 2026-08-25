// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Add to Archive: what the controls do when the user touches them.
//
// The other direction — view to model. Every handler mutates the model, asks it to
// reconcile, and redraws; none of them reads another control to decide what to do, so
// there is no ordering to get wrong.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

extension CompressDialogController {
    // MARK: - Actions

    @objc func formatChanged(_ sender: NSPopUpButton) {
        let formats = model.availableFormats
        guard formats.indices.contains(sender.indexOfSelectedItem) else { return }
        model.applyFormat(formats[sender.indexOfSelectedItem])
        refresh()
    }

    @objc func levelChanged(_ sender: NSPopUpButton) {
        let levels = model.levelChoices
        guard levels.indices.contains(sender.indexOfSelectedItem) else { return }
        model.level = levels[sender.indexOfSelectedItem]
        model.reconcile()
        refresh()
    }

    @objc func methodChanged(_ sender: NSPopUpButton) {
        let methods = model.methodChoices
        let index = sender.indexOfSelectedItem
        // Index 0 is the `*` entry: keep `nil` so no method property is emitted and the
        // handler picks its own default, which is what 7-Zip means by that asterisk.
        model.method = index <= 0 ? nil : (methods.indices.contains(index) ? methods[index] : nil)
        model.reconcile()
        refresh()
    }

    @objc func dictionaryChanged(_ sender: NSPopUpButton) {
        let choices = model.dictionaryChoices
        let index = sender.indexOfSelectedItem - 1
        model.dictionarySize = choices.indices.contains(index) ? .bytes(choices[index]) : .automatic
        model.reconcile()
        refresh()
    }

    @objc func wordSizeChanged(_ sender: NSPopUpButton) {
        let choices = model.wordSizeChoices
        let index = sender.indexOfSelectedItem - 1
        model.wordSize = choices.indices.contains(index) ? .value(choices[index]) : .automatic
        model.reconcile()
        refresh()
    }

    @objc func solidChanged(_ sender: NSPopUpButton) {
        let choices = model.solidChoices
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        model.solidBlockSize = choices[sender.indexOfSelectedItem]
        model.reconcile()
        refresh()
    }

    @objc func threadsChanged(_ sender: NSPopUpButton) {
        let choices = model.threadChoices
        let index = sender.indexOfSelectedItem - 1
        model.threads = choices.indices.contains(index) ? .count(choices[index]) : .automatic
        model.reconcile()
        refresh()
    }

    @objc func updateModeChanged(_ sender: NSPopUpButton) {
        let modes = model.updateModeChoices
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        model.updateMode = modes[sender.indexOfSelectedItem]
        refresh()
    }

    @objc func pathModeChanged(_ sender: NSPopUpButton) {
        let modes = CompressPathMode.allCases
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        model.pathMode = modes[sender.indexOfSelectedItem]
        refresh()
    }

    @objc func sfxToggled(_ sender: NSButton) {
        model.setSelfExtracting(sender.state == .on)
        refresh()
    }

    @objc func deleteToggled(_ sender: NSButton) {
        model.deleteSourcesAfterCompression = sender.state == .on
        refresh()
    }

    @objc func macOSMetadataToggled(_ sender: NSButton) {
        switch sender {
        case symlinkCheckbox:  model.storeSymbolicLinks = sender.state == .on
        case hardLinkCheckbox: model.storeHardLinks = sender.state == .on
        case xattrCheckbox:    model.storeExtendedAttributes = sender.state == .on
        case posixCheckbox:    model.storePOSIXPermissions = sender.state == .on
        default: return
        }
        refresh()
    }

    @objc func showPasswordToggled(_ sender: NSButton) {
        model.showPassword = sender.state == .on
        // Dropping the reenter field also drops the match requirement, so anything
        // already typed there stops mattering; clearing it avoids a stale mismatch
        // reappearing if the user turns the checkbox back off.
        if model.showPassword { model.verifyPassword = "" }
        refresh()
    }

    @objc func encryptionMethodChanged(_ sender: NSPopUpButton) {
        let ciphers = model.descriptor?.encryptionMethods ?? []
        guard ciphers.indices.contains(sender.indexOfSelectedItem) else { return }
        model.encryptionMethod = ciphers[sender.indexOfSelectedItem]
        refresh()
    }

    @objc func encryptNamesToggled(_ sender: NSButton) {
        model.encryptFileNames = sender.state == .on
        refresh()
    }

    @objc func volumeComboAction(_ sender: NSComboBox) {
        model.volumeText = sender.stringValue
        refreshValidation()
    }

    @objc func browsePressed(_ sender: Any?) {
        let save = NSSavePanel()
        save.title = "Browse"
        save.canCreateDirectories = true
        // Extensions are managed by the Format popup, not by the panel, so nothing is
        // appended behind the user's back.
        save.allowsOtherFileTypes = true

        let current = URL(fileURLWithPath: (model.archivePath as NSString).expandingTildeInPath)
        save.directoryURL = current.deletingLastPathComponent()
        save.nameFieldStringValue = current.lastPathComponent

        save.beginSheetModal(for: sheet) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = save.url else { return }
                self.model.archivePath = url.path
                // Picking `Backup.zip` in the panel means the user chose zip (ADD-04).
                self.model.adoptFormatFromArchivePath()
                self.refresh()
            }
        }
    }

    @objc func cancelPressed(_ sender: Any?) {
        finish(with: nil)
    }

    @objc func okPressed(_ sender: Any?) {
        let request: CompressRequest
        do {
            request = try model.makeRequest()
        } catch {
            presentFailure(error)
            return
        }

        // ADD-26: a volume small enough to produce thousands of files is more often a
        // typo (`10` meaning 10 MB) than an intention, so it is confirmed, not refused.
        if let last = request.volumeSizes.last,
           last < CompressDialogModel.VolumeSizeGrammar.tinyVolumeThreshold {
            confirmTinyVolume(last) { [weak self] proceed in
                guard let self, proceed else { return }
                finish(with: request)
            }
            return
        }

        finish(with: request)
    }

    private func confirmTinyVolume(_ bytes: UInt64, then handler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Specified volume size: \(bytes) bytes."
        alert.informativeText = "Are you sure you want to split archive into such volumes?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.beginSheetModal(for: sheet) { response in
            MainActor.assumeIsolated {
                handler(response == .alertFirstButtonReturn)
            }
        }
    }

    private func presentFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: sheet, completionHandler: nil)
    }

    // MARK: - Text editing

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }

        switch field {
        case archiveField:
            model.archivePath = field.stringValue
            model.adoptFormatFromArchivePath()
            // Do not call the full refresh here: it would rewrite the field the user is
            // typing into. Only the format-dependent controls need to catch up.
            refreshDependentControls()
            refreshValidation()

        case passwordSecureField, passwordPlainField:
            model.password = field.stringValue
            // Keep the hidden twin in step so toggling Show Password never loses text.
            let twin: NSTextField = field === passwordSecureField ? passwordPlainField : passwordSecureField
            if twin.stringValue != field.stringValue { twin.stringValue = field.stringValue }
            refreshValidation()

        case verifyField:
            model.verifyPassword = field.stringValue
            refreshValidation()

        case volumeCombo:
            model.volumeText = field.stringValue
            refreshValidation()

        case parametersField:
            model.parametersText = field.stringValue

        default:
            break
        }
    }

    public func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo === volumeCombo else { return }
        let index = combo.indexOfSelectedItem
        let presets = CompressDialogModel.VolumeSizeGrammar.presets
        guard presets.indices.contains(index) else { return }
        // `stringValue` is not updated yet at this point in the notification, so the
        // preset is read from the list rather than from the field.
        model.volumeText = presets[index]
        combo.stringValue = presets[index]
        refreshValidation()
    }

    /// Everything a format switch touches, minus the archive-path field itself.
    private func refreshDependentControls() {
        let archive = model.archivePath
        refresh()
        // `refresh()` writes the model's path back into the field; restore the caret by
        // leaving the text exactly as the user typed it.
        if archiveField.stringValue != archive { archiveField.stringValue = archive }
    }
}
