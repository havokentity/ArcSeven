// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Turning attacker-controlled bytes into something safe to put on screen.
//
// Both halves of this are security code, not convenience code. The decoder decides what a
// member is called; the sanitiser decides what the user is allowed to be shown. Quick Look
// is precisely the moment at which somebody decides whether an archive is safe to open, so
// a filename that lies about itself is worth more to an attacker here than almost anywhere
// else in the product.

import Foundation

enum ArchiveText {

    /// The upper half of code page 437, the encoding a ZIP member name is in when
    /// general-purpose flag bit 11 is clear.
    ///
    /// Stored as scalars rather than `Character` so that no two adjacent entries can be
    /// merged into a single grapheme cluster by Swift's own rules, which would silently
    /// shift every index after it.
    private static let codePage437High: [Unicode.Scalar] = Array(
        (
            "\u{00C7}\u{00FC}\u{00E9}\u{00E2}\u{00E4}\u{00E0}\u{00E5}\u{00E7}"
            + "\u{00EA}\u{00EB}\u{00E8}\u{00EF}\u{00EE}\u{00EC}\u{00C4}\u{00C5}"
            + "\u{00C9}\u{00E6}\u{00C6}\u{00F4}\u{00F6}\u{00F2}\u{00FB}\u{00F9}"
            + "\u{00FF}\u{00D6}\u{00DC}\u{00A2}\u{00A3}\u{00A5}\u{20A7}\u{0192}"
            + "\u{00E1}\u{00ED}\u{00F3}\u{00FA}\u{00F1}\u{00D1}\u{00AA}\u{00BA}"
            + "\u{00BF}\u{2310}\u{00AC}\u{00BD}\u{00BC}\u{00A1}\u{00AB}\u{00BB}"
            + "\u{2591}\u{2592}\u{2593}\u{2502}\u{2524}\u{2561}\u{2562}\u{2556}"
            + "\u{2555}\u{2563}\u{2551}\u{2557}\u{255D}\u{255C}\u{255B}\u{2510}"
            + "\u{2514}\u{2534}\u{252C}\u{251C}\u{2500}\u{253C}\u{255E}\u{255F}"
            + "\u{255A}\u{2554}\u{2569}\u{2566}\u{2560}\u{2550}\u{256C}\u{2567}"
            + "\u{2568}\u{2564}\u{2565}\u{2559}\u{2558}\u{2552}\u{2553}\u{256B}"
            + "\u{256A}\u{2518}\u{250C}\u{2588}\u{2584}\u{258C}\u{2590}\u{2580}"
            + "\u{03B1}\u{00DF}\u{0393}\u{03C0}\u{03A3}\u{03C3}\u{00B5}\u{03C4}"
            + "\u{03A6}\u{0398}\u{03A9}\u{03B4}\u{221E}\u{03C6}\u{03B5}\u{2229}"
            + "\u{2261}\u{00B1}\u{2265}\u{2264}\u{2320}\u{2321}\u{00F7}\u{2248}"
            + "\u{00B0}\u{2219}\u{00B7}\u{221A}\u{207F}\u{00B2}\u{25A0}\u{00A0}"
        ).unicodeScalars
    )

    /// Decode a ZIP member name.
    ///
    /// Flag bit 11 promises UTF-8, and when it is set we believe it. When it is clear the
    /// name is nominally code page 437, but a large minority of archivers write UTF-8
    /// without setting the flag, so UTF-8 is tried first and CP437 is the fallback. Strict
    /// decoding is what makes that safe: a genuine CP437 name containing high bytes is
    /// almost never also well-formed UTF-8, so the wrong branch is not taken by accident.
    static func decodeZIPName(_ raw: ArraySlice<UInt8>, declaresUTF8: Bool) -> String {
        let bytes = Array(raw)
        if let decoded = String(bytes: bytes, encoding: .utf8) { return decoded }
        if declaresUTF8 {
            // The archive said UTF-8 and was wrong. Salvage what decodes and mark the rest.
            return String(decoding: bytes, as: UTF8.self)
        }

        var result = ""
        result.unicodeScalars.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte < 0x80 {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                let index = Int(byte) - 0x80
                result.unicodeScalars.append(
                    index < codePage437High.count ? codePage437High[index] : "\u{FFFD}"
                )
            }
        }
        return result
    }

    /// Make a decoded name safe to draw.
    ///
    /// Three hazards, each of which reaches the screen unless it is removed here:
    ///
    ///   * control characters, which turn one table row into several or blank it out;
    ///   * the Unicode bidirectional overrides - the trick behind a name like
    ///     `invoice<U+202E>gnp.exe`, which renders as an innocuous image file while being
    ///     an executable;
    ///   * sheer length. A ZIP name field is 16-bit, so a legal name can be 64 KB of text.
    ///     That is a layout attack, not a filename.
    ///
    /// Path separators are deliberately NOT rewritten. Some Windows archivers store
    /// backslashes, but a backslash is also a legal character in a POSIX filename, and
    /// silently promoting one to a directory boundary would misrepresent the archive.
    static func sanitizedForDisplay(_ input: String) -> String {
        var result = ""
        var emitted = 0
        result.unicodeScalars.reserveCapacity(
            min(input.unicodeScalars.count, PreviewLimits.maxRenderedPathLength)
        )

        for scalar in input.unicodeScalars {
            if emitted >= PreviewLimits.maxRenderedPathLength {
                result.unicodeScalars.append("\u{2026}")
                break
            }
            result.unicodeScalars.append(isUnsafeForDisplay(scalar) ? "\u{FFFD}" : scalar)
            emitted += 1
        }
        return result.isEmpty ? "\u{FFFD}" : result
    }

    private static func isUnsafeForDisplay(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F:   return true    // C0 controls and DEL
        case 0x80...0x9F:         return true    // C1 controls
        case 0x200E, 0x200F:      return true    // LRM, RLM
        case 0x202A...0x202E:     return true    // the bidi embedding/override set
        case 0x2066...0x2069:     return true    // the bidi isolate set
        case 0x2028, 0x2029:      return true    // line and paragraph separators
        default:                  return false
        }
    }
}
