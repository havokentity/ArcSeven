// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The operation progress sheet.
//
// A first cut at 7zFM's progress dialog. That dialog has ten fields (Elapsed,
// Remaining, Files, Speed, Processed, Compressed size, Ratio, …) plus Background and
// Pause buttons; this shows the subset the CLI engine can actually supply today —
// the subprocess reports a percentage, a file count and the current path, and
// nothing else. Inventing a Speed readout from interpolated percentages would be
// worse than omitting it. The full dialog lands with the in-process engine.

import AppKit

/// A modal sheet showing the progress of one operation.
@MainActor
public final class ProgressSheetController: NSObject {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 168),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    private let titleLabel: NSTextField
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    private weak var host: NSWindow?
    private var isFinished = false
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// Invoked when the user cancels.
    ///
    /// The caller cancels its own Task, which tears down the child process group;
    /// `7zz` unwinds on SIGINT and deletes the partial archive it was writing.
    public var onCancel: (@MainActor () -> Void)?

    public init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init()

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        // A long member path must not stretch the sheet; it truncates instead.
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"   // Escape

        let buttonRow = NSStackView(views: [NSView(), cancelButton])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, bar, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 380),
            detailLabel.widthAnchor.constraint(equalToConstant: 380),
            buttonRow.widthAnchor.constraint(equalToConstant: 380),
        ])
        panel.contentView = content
    }

    /// Show the sheet on a window.
    public func present(in window: NSWindow) {
        host = window
        window.beginSheet(panel)
    }

    /// Update from an engine progress tick.
    ///
    /// The bar switches from indeterminate to determinate the first time a real
    /// percentage arrives, because early ticks often carry none.
    public func update(fraction: Double?, detail: String) {
        guard !isFinished else { return }
        if let fraction {
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            bar.doubleValue = min(max(fraction, 0), 1)
        }
        detailLabel.stringValue = detail
    }

    @objc private func cancelClicked() {
        guard !isFinished else { return }
        cancelButton.isEnabled = false
        cancelButton.title = "Cancelling…"
        onCancel?()
    }

    /// Dismiss the sheet. Safe to call more than once.
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        bar.stopAnimation(nil)
        host?.endSheet(panel)
        panel.orderOut(nil)
    }
}
