// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Running an engine operation behind the progress sheet, and reporting how it went.
//
// Split out of MainWindowController.swift purely for size; this is the same type.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif
#if canImport(Support)   // module-guard
import Support
#endif

extension MainWindowController {
    func run(
        operation: ArchiveOperationStream,
        title: String,
        completion: @escaping @MainActor (ArchiveOperationResult) -> Void,
        onSettled: (@MainActor () -> Void)? = nil
    ) {
        guard let window else {
            onSettled?()
            return
        }
        let progress = ProgressSheetController(title: title)
        progress.present(in: window)

        let task = Task { @MainActor in
            // The sheet is modal: if it is not dismissed the window is unusable and the
            // only way out is force-quitting. `finish()` is idempotent and guarded by
            // `isFinished`, so dismissing here as well as on each terminal event costs
            // nothing and removes the whole class of "stream ended in a way nobody
            // anticipated, sheet stayed up forever".
            //
            // Defence in depth rather than a fix for a reproduced hang: every path
            // through the engine's operation stream currently either yields `.finished`
            // or throws. This keeps that from being load-bearing.
            defer {
                progress.finish()
                onSettled?()
            }
            do {
                for try await event in operation {
                    switch event {
                    case .progress(let tick):
                        progress.update(
                            fraction: tick.fractionCompleted,
                            detail: tick.currentItemPath ?? ""
                        )
                    case .finished(let result):
                        progress.finish()
                        completion(result)
                    default:
                        break
                    }
                }
            } catch is CancellationError {
                progress.finish()
            } catch {
                progress.finish()
                self.reportFailure(error)
            }
        }
        progress.onCancel = { task.cancel() }
    }

    func reportSuccess(
        _ result: ArchiveOperationResult,
        title: String,
        detail: String,
        reveal: URL?
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        var text = detail
        if result.hasWarnings {
            // Exit code 1 is success-with-warnings. Show them; do not call it a failure.
            text += "\n\n\(result.warnings.count) warning(s):\n"
                + result.warnings.prefix(5).map(\.message).joined(separator: "\n")
        }
        alert.informativeText = text
        if reveal != nil { alert.addButton(withTitle: "Reveal in Finder") }
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { response in
            if let reveal, response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([reveal])
            }
        }
    }

    /// Report a failure, naming a password problem specifically when that is the cause.
    ///
    /// Named `reportFailure` rather than `presentError`: `NSResponder` already declares
    /// `presentError(_:) -> Bool`, and overloading it here is ambiguous at every call site.
    ///
    /// Internal rather than private: callers live in MainWindowController.swift too.
    func reportFailure(_ error: any Error) {
        if let archiveError = error as? ArchiveError, archiveError.needsPassword {
            presentMessage(
                "Wrong password",
                "That password did not open the archive. Try opening it again."
            )
            return
        }
        presentMessage("The operation failed", error.localizedDescription)
    }
}
