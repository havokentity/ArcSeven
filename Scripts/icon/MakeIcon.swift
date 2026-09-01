// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Draws ArcSeven's app icon and emits a complete .iconset.
//
// The icon is code rather than a binary blob so it can be reviewed in a diff, tweaked
// without a design tool, and regenerated at any size. Run via Scripts/make-icon.sh.
//
// The mark: a HEPTAGON — seven sides, for the seven in the name and the 7z lineage —
// holding three stacked bars that step inward, reading as content being compressed. It
// is deliberately a silhouette with one accent, because the thing that actually matters
// for an app icon is whether it survives 16×16 in a Finder list. Fine detail and
// gradients inside the glyph are what turn small icons to mush, so there are none.

import AppKit

// MARK: - Geometry

/// A rounded regular polygon, flat-topped, centred in `rect`.
func roundedPolygonPath(sides: Int, rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    // -90° puts a vertex at the top, which reads as "pointing up" rather than tilted.
    let start = -CGFloat.pi / 2
    let points = (0..<sides).map { index -> CGPoint in
        let angle = start + (2 * .pi * CGFloat(index) / CGFloat(sides))
        return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }

    let path = CGMutablePath()
    for index in 0..<sides {
        let previous = points[(index - 1 + sides) % sides]
        let current = points[index]
        let next = points[(index + 1) % sides]
        if index == 0 {
            // Start partway along the first edge so the arcs join cleanly.
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.move(to: midpoint)
        }
        path.addArc(tangent1End: current, tangent2End: next, radius: cornerRadius)
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func drawIcon(size: CGFloat, into context: CGContext) {
    let scale = size / 1024
    func s(_ value: CGFloat) -> CGFloat { value * scale }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // --- Background: the macOS squircle ---------------------------------------------
    //
    // Inset because macOS expects an icon to sit inside its 1024 canvas with margin;
    // filling edge to edge makes it look oversized next to every system icon.
    let inset = s(100)
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = s(200)
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil
    )

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    // Indigo to violet, light at the top — the direction macOS lights everything from.
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [0.35, 0.42, 0.95, 1])!,
            CGColor(colorSpace: space, components: [0.29, 0.20, 0.72, 1])!,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // --- The heptagon ----------------------------------------------------------------
    let glyphSide = plate.width * 0.62
    let glyph = CGRect(
        x: plate.midX - glyphSide / 2,
        y: plate.midY - glyphSide / 2,
        width: glyphSide,
        height: glyphSide
    )
    let heptagon = roundedPolygonPath(sides: 7, rect: glyph, cornerRadius: s(46))

    context.saveGState()
    context.addPath(heptagon)
    context.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.96])!)
    context.setLineWidth(s(54))
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    // --- Three stacked bars, stepping inward -----------------------------------------
    //
    // Widest at the bottom, narrowest at the top: content being squeezed. The top bar is
    // the accent colour so there is exactly one point of contrast, which is what makes
    // the icon identifiable in a crowded Dock.
    context.saveGState()
    context.addPath(heptagon)
    context.clip()

    let barHeight = s(74)
    let barGap = s(38)
    let widths: [CGFloat] = [glyph.width * 0.56, glyph.width * 0.42, glyph.width * 0.28]
    let colours = [
        CGColor(colorSpace: space, components: [1, 1, 1, 0.95])!,
        CGColor(colorSpace: space, components: [1, 1, 1, 0.95])!,
        CGColor(colorSpace: space, components: [1.0, 0.78, 0.25, 1])!,   // amber accent
    ]
    let stackHeight = barHeight * 3 + barGap * 2
    var y = glyph.midY - stackHeight / 2 - s(10)
    for (index, width) in widths.enumerated() {
        let bar = CGRect(x: glyph.midX - width / 2, y: y, width: width, height: barHeight)
        context.addPath(
            CGPath(roundedRect: bar, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2,
                   transform: nil)
        )
        context.setFillColor(colours[index])
        context.fillPath()
        y += barHeight + barGap
    }
    context.restoreGState()
}

// MARK: - Emit

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// The exact set `iconutil` requires. A missing entry makes it fail with a message that
/// does not name the missing file, so the list is spelled out rather than derived.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let pixels = Int(variant.pixels)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(pixels)px context") }

    drawIcon(size: variant.pixels, into: context)

    guard let image = context.makeImage() else { fatalError("no image at \(pixels)px") }
    let destination = outputDirectory.appendingPathComponent(variant.name)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed at \(pixels)px")
    }
    try data.write(to: destination)
    print("  \(variant.name) (\(pixels)px)")
}
print("iconset written to \(outputDirectory.path)")
