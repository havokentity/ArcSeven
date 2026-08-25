// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Draws the per-format document icons and emits one .iconset per format.
//
// These are the icons Finder puts on a .7z or .zip once ArcSeven is the handler. The
// plist has referenced doc-7z.icns and friends since M0; the files never existed, which
// is why archives showed the generic blank-page icon.
//
// ## What actually makes a document icon work
//
// A document icon is read at 16pt in a Finder list far more often than at 512. At that
// size a label is 4pt tall and completely illegible, so the thing that has to do the
// work is SHAPE and COLOUR:
//
//   * every format shares one silhouette — a page with a folded corner — so they read
//     as "a document ArcSeven owns" at a glance;
//   * each format gets its own hue, so .zip and .7z are distinguishable in a folder
//     without reading anything;
//   * the label is drawn for the large sizes, where it disambiguates formats that share
//     a family colour, and is simply omitted below 64px rather than rendered as mush.
//
// The heptagon from the app icon is stamped small in the page body to tie the two
// together without competing with the label.

import AppKit

// MARK: - Format table

struct DocumentFormat {
    let file: String        // output basename, matching CFBundleTypeIconFile
    let label: String       // drawn on the large sizes
    let colour: (CGFloat, CGFloat, CGFloat)

    static let all: [DocumentFormat] = [
        // The brand indigo goes to 7z: it is the format the app is named for.
        DocumentFormat(file: "doc-7z",      label: "7z",   colour: (0.35, 0.42, 0.95)),
        DocumentFormat(file: "doc-zip",     label: "ZIP",  colour: (0.13, 0.63, 0.55)),
        DocumentFormat(file: "doc-rar",     label: "RAR",  colour: (0.58, 0.35, 0.80)),
        DocumentFormat(file: "doc-tar",     label: "TAR",  colour: (0.85, 0.55, 0.20)),
        DocumentFormat(file: "doc-gz",      label: "GZ",   colour: (0.25, 0.62, 0.30)),
        DocumentFormat(file: "doc-bz2",     label: "BZ2",  colour: (0.83, 0.32, 0.29)),
        DocumentFormat(file: "doc-xz",      label: "XZ",   colour: (0.20, 0.52, 0.78)),
        DocumentFormat(file: "doc-cab",     label: "CAB",  colour: (0.30, 0.36, 0.47)),
        // Deliberately grey: it stands for two dozen formats with nothing in common, and
        // colouring it would imply a specificity it does not have. Kept noticeably
        // LIGHTER than doc-cab — the first pass had them within a few percent of each
        // other and they were indistinguishable at 32px, which is the size that matters.
        DocumentFormat(file: "doc-generic", label: "FILE", colour: (0.65, 0.68, 0.73)),
    ]
}

// MARK: - Drawing

func roundedHeptagon(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    let start = -CGFloat.pi / 2
    let points = (0..<7).map { index -> CGPoint in
        let angle = start + (2 * .pi * CGFloat(index) / 7)
        return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }
    let path = CGMutablePath()
    for index in 0..<7 {
        let previous = points[(index - 1 + 7) % 7]
        let current = points[index]
        let next = points[(index + 1) % 7]
        if index == 0 {
            path.move(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2))
        }
        path.addArc(tangent1End: current, tangent2End: next, radius: cornerRadius)
    }
    path.closeSubpath()
    return path
}

func drawDocument(_ format: DocumentFormat, size: CGFloat, into context: CGContext) {
    let scale = size / 1024
    func s(_ value: CGFloat) -> CGFloat { value * scale }
    let space = CGColorSpaceCreateDeviceRGB()
    func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a])!
    }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Page geometry. Taller than wide, like a sheet of paper, inset so it sits inside
    // the 1024 canvas the way system document icons do.
    let pageWidth = s(660)
    let pageHeight = s(840)
    let origin = CGPoint(x: (size - pageWidth) / 2, y: (size - pageHeight) / 2)
    let fold = s(210)                       // size of the turned-down corner
    let radius = s(46)

    // --- page outline with a folded top-right corner -------------------------------
    let page = CGMutablePath()
    let left = origin.x, right = origin.x + pageWidth
    let bottom = origin.y, top = origin.y + pageHeight
    page.move(to: CGPoint(x: left + radius, y: bottom))
    page.addLine(to: CGPoint(x: right - radius, y: bottom))
    page.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
    page.addLine(to: CGPoint(x: right, y: top - fold))
    page.addLine(to: CGPoint(x: right - fold, y: top))
    page.addLine(to: CGPoint(x: left + radius, y: top))
    page.addQuadCurve(to: CGPoint(x: left, y: top - radius), control: CGPoint(x: left, y: top))
    page.addLine(to: CGPoint(x: left, y: bottom + radius))
    page.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
    page.closeSubpath()

    context.saveGState()
    context.addPath(page)
    context.setFillColor(colour(1, 1, 1))
    context.fillPath()
    context.addPath(page)
    context.setStrokeColor(colour(0.78, 0.80, 0.84))
    context.setLineWidth(s(8))
    context.strokePath()
    context.restoreGState()

    // --- the fold itself, drawn as a lighter triangle so the corner reads as turned --
    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: right - fold, y: top))
    foldPath.addLine(to: CGPoint(x: right, y: top - fold))
    foldPath.addLine(to: CGPoint(x: right - fold, y: top - fold))
    foldPath.closeSubpath()
    context.saveGState()
    context.addPath(foldPath)
    context.setFillColor(colour(0.88, 0.90, 0.93))
    context.fillPath()
    context.restoreGState()

    // --- colour band across the lower third ------------------------------------------
    let bandHeight = s(250)
    let band = CGRect(x: left, y: bottom, width: pageWidth, height: bandHeight)
    context.saveGState()
    // Clip to the page so the band picks up the page's rounded bottom corners.
    context.addPath(page)
    context.clip()
    context.addRect(band)
    context.setFillColor(colour(format.colour.0, format.colour.1, format.colour.2))
    context.fillPath()
    context.restoreGState()

    // --- heptagon watermark, tying these to the app icon ------------------------------
    let markSide = s(300)
    let mark = CGRect(
        x: origin.x + (pageWidth - markSide) / 2,
        y: bottom + bandHeight + s(120),
        width: markSide, height: markSide
    )
    context.saveGState()
    context.addPath(roundedHeptagon(in: mark, cornerRadius: s(28)))
    context.setStrokeColor(colour(format.colour.0, format.colour.1, format.colour.2, 0.9))
    context.setLineWidth(s(34))
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    // --- label, large sizes only ------------------------------------------------------
    //
    // Below 64px a label is a few pixels tall and turns to mush; the band colour is doing
    // the identification at those sizes, so the text is simply left out.
    guard size >= 64 else { return }
    let fontSize = bandHeight * 0.52
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let text = NSAttributedString(string: format.label, attributes: attributes)
    let textSize = text.size()
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    text.draw(at: CGPoint(
        x: band.midX - textSize.width / 2,
        y: band.midY - textSize.height / 2
    ))
    NSGraphicsContext.current = previous
}

// MARK: - Emit

let outputRoot = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "DocumentIcons")
try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for format in DocumentFormat.all {
    let iconset = outputRoot.appendingPathComponent("\(format.file).iconset")
    try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for variant in variants {
        let pixels = Int(variant.pixels)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("no context at \(pixels)px") }
        drawDocument(format, size: variant.pixels, into: context)
        guard let image = context.makeImage() else { fatalError("no image at \(pixels)px") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("PNG encoding failed at \(pixels)px")
        }
        try data.write(to: iconset.appendingPathComponent(variant.name))
    }
    print("  \(format.file).iconset  (\(format.label))")
}
print("document iconsets written to \(outputRoot.path)")
