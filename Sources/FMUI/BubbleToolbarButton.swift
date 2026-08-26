// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The toolbar's colour-coded buttons.
//
// 7zFM's toolbar is seven grey bitmaps that differ only in glyph, which means telling Add
// from Extract is a reading task every single time. Colour makes it a glance: the eye finds
// "the green one" far faster than it finds the word "Add", and the seven hues stay stable
// wherever the button appears.
//
// The shape is the rounded-square badge macOS uses in Settings and Shortcuts, so it reads as
// native rather than as a web button that wandered in. Everything here is drawn from system
// colours, which is what keeps it correct in dark mode, in Increase Contrast, and under an
// accent-colour change, none of which a hand-picked palette survives.

import AppKit

/// A toolbar button drawn as a coloured badge with a white glyph.
///
/// `NSButton` rather than a bare `NSView`: it inherits the whole accessibility story — role,
/// title, activation, keyboard focus ring — which a custom view has to reimplement badly.
@MainActor
final class BubbleToolbarButton: NSButton {
    private let tint: NSColor
    private let symbol: String

    /// Hover and press are drawn, not animated with layers: a toolbar button is a 28-point
    /// target that people click thousands of times, and a spring animation on every press
    /// becomes noise long before it becomes charming.
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    private static let badgeSize = NSSize(width: 30, height: 30)
    private static let cornerRadius: CGFloat = 8.5

    init(symbol: String, tint: NSColor, title: String) {
        self.tint = tint
        self.symbol = symbol
        super.init(frame: NSRect(origin: .zero, size: Self.badgeSize))
        self.title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        setAccessibilityLabel(title)
        toolTip = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { Self.badgeSize }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let badge = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(
            roundedRect: badge, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Disabled reads as "absent", not "grey": a full-colour badge at low alpha still
        // carries its identity, so the toolbar does not rearrange itself visually when a
        // selection changes.
        let alpha: CGFloat = isEnabled ? 1.0 : 0.35
        let base = isPressed ? tint.blended(withFraction: 0.18, of: .black) ?? tint
            : isHovered ? tint.blended(withFraction: 0.12, of: .white) ?? tint
            : tint

        // A two-stop vertical gradient, lighter at the top. This is the whole "bubble": a
        // flat fill reads as a tag, a gradient reads as a physical object catching light.
        let top = base.blended(withFraction: 0.22, of: .white) ?? base
        let gradient = NSGradient(
            colors: [top.withAlphaComponent(alpha), base.withAlphaComponent(alpha)]
        )
        gradient?.draw(in: path, angle: -90)

        // Specular highlight along the top edge.
        //
        // A gradient, not a filled oval: an oval clipped to the badge leaves a hard curved
        // seam across the middle, which at 30 points reads as a rendering artefact rather
        // than as light. Fading to clear puts the brightness where the light would be and
        // nowhere else.
        path.setClip()
        let gloss = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.28 * alpha),
            NSColor.white.withAlphaComponent(0.0),
        ])
        gloss?.draw(
            in: NSRect(
                x: badge.minX,
                y: badge.midY,
                width: badge.width,
                height: badge.height / 2
            ),
            angle: -90
        )

        drawSymbol(in: badge, alpha: alpha)
    }

    private func drawSymbol(in badge: NSRect, alpha: CGFloat) {
        // `paletteColors` rather than a template tint: an SF Symbol drawn as a template
        // picks up the current fill colour, which inside a toolbar is whatever AppKit last
        // set — usually black, which is invisible on a saturated badge.
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }

        let size = image.size
        let rect = NSRect(
            x: badge.midX - size.width / 2,
            y: badge.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral

        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

/// The seven toolbar actions, with the identity each one carries everywhere it appears.
///
/// Colour is assigned by consequence, not decoration, and the mapping is the conventional
/// one so it needs no learning: green creates, blue and orange move things about, red
/// destroys. Delete is the only red in the toolbar, which is the point — the destructive
/// button should never be findable by muscle memory alone.
///
/// Lifted out of `MainWindowController` so the drawing can be tested without standing up a
/// window.
@MainActor
enum ToolbarActionStyle: String, CaseIterable {
    case add, extract, test, copy, move, delete, info

    var title: String {
        switch self {
        case .add: "Add"
        case .extract: "Extract"
        case .test: "Test"
        case .copy: "Copy"
        case .move: "Move"
        case .delete: "Delete"
        case .info: "Info"
        }
    }

    /// SF Symbols standing in for 7-Zip's bitmaps.
    var symbolName: String {
        switch self {
        case .add: "plus.rectangle.on.folder"
        case .extract: "arrow.down.doc"
        case .test: "checkmark.seal"
        case .copy: "doc.on.doc"
        case .move: "arrow.right.doc.on.clipboard"
        case .delete: "trash"
        case .info: "info.circle"
        }
    }

    /// System colours only. They adapt to dark mode, to Increase Contrast, and to the
    /// user's accent colour; a hex palette would be wrong in all three.
    var tint: NSColor {
        switch self {
        case .add: .systemGreen
        case .extract: .systemBlue
        case .test: .systemTeal
        case .copy: .systemIndigo
        case .move: .systemOrange
        case .delete: .systemRed
        case .info: .systemPurple
        }
    }

    var itemIdentifier: NSToolbarItem.Identifier { .init("ArcSeven." + rawValue) }
}
