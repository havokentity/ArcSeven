// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import AppKit
import Foundation
import Testing
import ArchiveCore
@testable import FMUI

/// Toolbar badges are drawn by hand, so the things that can break are drawing things: a
/// symbol name Apple renamed, a glyph that ends up invisible against its own background, a
/// badge that renders empty. None of that is a compile error.
@MainActor
@Suite("Bubble toolbar button")
struct BubbleToolbarButtonTests {
    private func render(_ button: BubbleToolbarButton) -> NSBitmapImageRep? {
        button.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
        button.cacheDisplay(in: button.bounds, to: rep)
        return rep
    }

    @Test("Every toolbar symbol resolves")
    func symbolsResolve() {
        for action in ToolbarActionStyle.allCases {
            #expect(
                NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil) != nil,
                "\(action.title): SF Symbol '\(action.symbolName)' does not resolve"
            )
        }
    }

    @Test("Each badge draws its own colour, not an empty rectangle")
    func badgesDrawColour() {
        for action in ToolbarActionStyle.allCases {
            let button = BubbleToolbarButton(
                symbol: action.symbolName, tint: action.tint, title: action.title
            )
            guard let rep = render(button) else {
                Issue.record("\(action.title): produced no bitmap")
                continue
            }
            // Centre of the badge: saturated colour, or a white glyph stroke over it.
            let centre = rep.colorAt(x: 15, y: 15)
            #expect(centre != nil, "\(action.title): nothing drawn")
            #expect((centre?.alphaComponent ?? 0) > 0.5, "\(action.title): badge is transparent")
        }
    }

    /// The glyph is white on a saturated fill. If a future change lets it fall back to the
    /// template colour it goes black-on-colour, which is the bug this catches.
    @Test("The glyph is legible against its badge")
    func glyphContrastsWithBadge() {
        let action = ToolbarActionStyle.delete   // red: the least forgiving background
        let button = BubbleToolbarButton(
            symbol: action.symbolName, tint: action.tint, title: action.title
        )
        guard let rep = render(button) else {
            Issue.record("no bitmap")
            return
        }

        var brightest: CGFloat = 0
        for x in 8..<22 {
            for y in 8..<22 {
                guard let pixel = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else { continue }
                brightest = max(brightest, pixel.brightnessComponent)
            }
        }
        #expect(brightest > 0.85, "no near-white pixels: the glyph is not rendering white")
    }

    @Test("Buttons carry an accessibility label")
    func accessible() {
        for action in ToolbarActionStyle.allCases {
            let button = BubbleToolbarButton(
                symbol: action.symbolName, tint: action.tint, title: action.title
            )
            #expect(button.accessibilityLabel() == action.title)
        }
    }

    /// Writes the whole toolbar strip to a PNG so the design can be looked at rather than
    /// argued about. Off unless `ARCSEVEN_RENDER_TOOLBAR` names a destination directory.
    @Test("Render the toolbar strip for inspection")
    func renderStrip() throws {
        guard let directory = ProcessInfo.processInfo.environment["ARCSEVEN_RENDER_TOOLBAR"] else {
            return
        }
        let cell: CGFloat = 30, gap: CGFloat = 16, pad: CGFloat = 16, labelBand: CGFloat = 20
        let actions = ToolbarActionStyle.allCases
        let width = pad * 2 + CGFloat(actions.count) * cell + CGFloat(actions.count - 1) * gap
        let bandHeight = pad * 2 + cell + labelBand
        let height = bandHeight * 2   // light over dark

        let strip = NSImage(size: NSSize(width: width, height: height))
        strip.lockFocus()
        for (bandIndex, appearanceName) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
        let appearance = NSAppearance(named: appearanceName)
        let bandOrigin = height - CGFloat(bandIndex + 1) * bandHeight
        appearance?.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: bandOrigin, width: width, height: bandHeight).fill()
        for (index, action) in actions.enumerated() {
            let button = BubbleToolbarButton(
                symbol: action.symbolName, tint: action.tint, title: action.title
            )
            let originX = pad + CGFloat(index) * (cell + gap)
            button.appearance = appearance
            button.frame = NSRect(
                x: originX, y: bandOrigin + pad + labelBand, width: cell, height: cell
            )
            if let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: rep)
                if let cgImage = rep.cgImage {
                    NSImage(cgImage: cgImage, size: button.bounds.size).draw(in: button.frame)
                }
            }
            let label = NSAttributedString(string: action.title, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.labelColor,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: originX + (cell - size.width) / 2, y: bandOrigin + pad + 2))
        }
        }
        }
        strip.unlockFocus()

        let scale: CGFloat = 4
        let large = NSImage(size: NSSize(width: width * scale, height: height * scale))
        large.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        strip.draw(in: NSRect(origin: .zero, size: large.size))
        large.unlockFocus()

        guard let tiff = large.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            Issue.record("could not encode PNG")
            return
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("toolbar.png"))
    }

    /// The badge only reaches the screen if the toolbar delegate actually installs it as the
    /// item's view. Asserting on the delegate's own output rather than on a screenshot: a
    /// screenshot of the wrong build looks exactly like a screenshot of a broken one, which
    /// is a mistake already made once while developing this.
    @Test("The toolbar delegate installs a badge for every action")
    func toolbarUsesBadges() throws {
        let engine = SevenZipCLIEngine(
            executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
        )
        let controller = MainWindowController(
            startingAt: URL(fileURLWithPath: NSTemporaryDirectory()), engine: engine
        )
        let toolbar = NSToolbar(identifier: "test")

        for action in ToolbarActionStyle.allCases {
            let item = controller.toolbar(
                toolbar, itemForItemIdentifier: action.itemIdentifier, willBeInsertedIntoToolbar: true
            )
            let view = try #require(item?.view, "\(action.title): no custom view installed")
            #expect(view is BubbleToolbarButton, "\(action.title): view is \(type(of: view))")
            #expect(item?.label == action.title)

            // Wired to something: an unset action makes a beautiful, inert button.
            let button = try #require(view as? NSButton)
            #expect(button.action != nil, "\(action.title): button has no action")
            #expect(button.target != nil, "\(action.title): button has no target")
        }
    }

    /// The action is recovered from the button's accessibility label, so every title must be
    /// distinct or two buttons would run the same command.
    @Test("Action titles are unique")
    func titlesAreUnique() {
        let titles = ToolbarActionStyle.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
    }
}
